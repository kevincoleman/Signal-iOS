//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import Argon2

@objc(OWSKeyBackupService)
public class KeyBackupService: NSObject {
    public enum KBSError: Error {
        case assertion
        case invalidPin(triesRemaining: UInt32)
        case backupMissing
    }

    public enum PinType: Int {
        case numeric = 1
        case alphanumeric = 2

        public init(forPin pin: String) {
            let normalizedPin = KeyBackupService.normalizePin(pin)
            self = normalizedPin.digitsOnly() == normalizedPin ? .numeric : .alphanumeric
        }
    }

    // PRAGMA MARK: - Depdendencies
    static var networkManager: TSNetworkManager {
        return TSNetworkManager.shared()
    }

    static var databaseStorage: SDSDatabaseStorage {
        return .shared
    }

    static var tsAccountManager: TSAccountManager {
        return .sharedInstance()
    }

    static var storageServiceManager: StorageServiceManagerProtocol {
        return SSKEnvironment.shared.storageServiceManager
    }

    static var syncManager: SyncManagerProtocol {
        return SSKEnvironment.shared.syncManager
    }

    // PRAGMA MARK: - Pin Management

    static let maximumKeyAttempts: UInt32 = 10

    /// Indicates whether or not we have a master key stored in KBS
    @objc
    public static var hasMasterKey: Bool {
        return cacheQueue.sync { cachedMasterKey != nil }
    }

    public static var currentPinType: PinType? {
        return cacheQueue.sync { cachedPinType }
    }

    /// Indicates whether your pin is valid when compared to your stored keys.
    /// This is a local verification and does not make any requests to the KBS.
    @objc
    public static func verifyPin(_ pin: String, resultHandler: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            var isValid = false
            defer {
                DispatchQueue.main.async { resultHandler(isValid) }
            }

            guard let encodedVerificationString = cacheQueue.sync(execute: { cachedEncodedVerificationString }) else {
                owsFailDebug("Attempted to verify pin locally when we don't have a verification string")
                return
            }

            guard let pinData = normalizePin(pin).data(using: .utf8) else {
                owsFailDebug("failed to determine pin data")
                return
            }

            do {
                isValid = try Argon2.verify(encoded: encodedVerificationString, password: pinData, variant: .i)
            } catch {
                owsFailDebug("Failed to validate encodedVerificationString with error: \(error)")
            }
        }
    }

    @objc(restoreKeysWithPin:)
    static func objc_RestoreKeys(with pin: String) -> AnyPromise {
        return AnyPromise(restoreKeys(with: pin))
    }

    /// Loads the users key, if any, from the KBS into the database.
    public static func restoreKeys(with pin: String, and auth: RemoteAttestationAuth? = nil) -> Promise<Void> {
        return fetchBackupId(auth: auth).map(on: .global()) { backupId in
            return try deriveEncryptionKeyAndAccessKey(pin: pin, backupId: backupId)
        }.then { encryptionKey, accessKey in
            restoreKeyRequest(accessKey: accessKey, with: auth).map { ($0, encryptionKey, accessKey) }
        }.map(on: .global()) { response, encryptionKey, accessKey -> (Data, Data, Data) in
            guard let status = response.status else {
                owsFailDebug("KBS restore is missing status")
                throw KBSError.assertion
            }

            // As long as the backup exists we should always receive a
            // new token to use on our next request. Store it now.
            if status != .missing {
                guard let tokenData = response.token else {
                    owsFailDebug("KBS restore is missing token")
                    throw KBSError.assertion
                }

                try Token.updateNext(data: tokenData, tries: response.tries)
            }

            switch status {
            case .tokenMismatch:
                // the given token has already been spent. we'll use the new token
                // on the next attempt.
                owsFailDebug("attempted restore with spent token")
                throw KBSError.assertion
            case .pinMismatch:
                throw KBSError.invalidPin(triesRemaining: response.tries)
            case .missing:
                throw KBSError.backupMissing
            case .notYetValid:
                owsFailDebug("the server thinks we provided a `validFrom` in the future")
                throw KBSError.assertion
            case .ok:
                guard let encryptedMasterKey = response.data else {
                    owsFailDebug("Failed to extract encryptedMasterKey from successful KBS restore response")
                    throw KBSError.assertion
                }

                let masterKey = try decryptMasterKey(encryptedMasterKey, encryptionKey: encryptionKey)

                return (masterKey, encryptedMasterKey, accessKey)
            }
        }.then { masterKey, encryptedMasterKey, accessKey in
            // Backup our keys again, even though we just fetched them.
            // This resets the number of remaining attempts.
            backupKeyRequest(accessKey: accessKey, encryptedMasterKey: encryptedMasterKey, and: auth).map { ($0, masterKey) }
        }.done(on: .global()) { response, masterKey in
            guard let status = response.status else {
                owsFailDebug("KBS backup is missing status")
                throw KBSError.assertion
            }

            guard let tokenData = response.token else {
                owsFailDebug("KBS restore is missing token")
                throw KBSError.assertion
            }

            // We should always receive a new token to use on our next request.
            try Token.updateNext(data: tokenData)

            switch status {
            case .alreadyExists:
                // If we receive already exists, this means our backup has expired and
                // been replaced. In normal circumstances this should never happen.
                owsFailDebug("Received ALREADY_EXISTS response from KBS")
                throw KBSError.assertion
            case .notYetValid:
                owsFailDebug("the server thinks we provided a `validFrom` in the future")
                throw KBSError.assertion
            case .ok:
                let encodedVerificationString = try deriveEncodedVerificationString(pin: pin)

                // We successfully stored the new keys in KBS, save them in the database
                databaseStorage.write { transaction in
                    store(masterKey, pinType: PinType(forPin: pin), encodedVerificationString: encodedVerificationString, transaction: transaction)
                }
            }
        }.recover { error in
            guard let kbsError = error as? KBSError else {
                owsFailDebug("Unexpectedly surfacing a non KBS error \(error)")
                throw error
            }

            throw kbsError
        }
    }

    @objc(generateAndBackupKeysWithPin:)
    static func objc_generateAndBackupKeys(with pin: String) -> AnyPromise {
        return AnyPromise(generateAndBackupKeys(with: pin))
    }

    /// Backs up the user's master key to KBS and stores it locally in the database.
    /// If the user doesn't have a master key already a new one is generated.
    public static func generateAndBackupKeys(with pin: String) -> Promise<Void> {
        return fetchBackupId(auth: nil).map(on: .global()) { backupId -> (Data, Data, Data) in
            let masterKey = cacheQueue.sync { cachedMasterKey } ?? generateMasterKey()
            let (encryptionKey, accessKey) = try deriveEncryptionKeyAndAccessKey(pin: pin, backupId: backupId)
            let encryptedMasterKey = try encryptMasterKey(masterKey, encryptionKey: encryptionKey)

            return (masterKey, encryptedMasterKey, accessKey)
        }.then { masterKey, encryptedMasterKey, accessKey in
            firstly {
                backupKeyRequest(accessKey: accessKey, encryptedMasterKey: encryptedMasterKey)
            }.tap {
                switch $0 {
                case .fulfilled:
                    break
                case .rejected(let error):
                    Logger.error("recording backupKeyRequest errored: \(error)")
                    databaseStorage.write {
                        self.keyValueStore.setBool(true, key: hasBackupKeyRequestFailedIdentifier, transaction: $0)
                    }
                }
            }.map { ($0, masterKey) }
        }.done(on: .global()) { response, masterKey in
            guard let status = response.status else {
                owsFailDebug("KBS backup is missing status")
                throw KBSError.assertion
            }

            guard let tokenData = response.token else {
                owsFailDebug("KBS restore is missing token")
                throw KBSError.assertion
            }

            // We should always receive a new token to use on our next request. Store it now.
            try Token.updateNext(data: tokenData)

            switch status {
            case .alreadyExists:
                // the given token has already been spent. we'll use the new token
                // on the next attempt.
                owsFailDebug("attempted restore with spent token")
            case .notYetValid:
                owsFailDebug("the server thinks we provided a `validFrom` in the future")
                throw KBSError.assertion
            case .ok:
                let encodedVerificationString = try deriveEncodedVerificationString(pin: pin)

                // We successfully stored the new keys in KBS, save them in the database
                databaseStorage.write { transaction in
                    store(masterKey, pinType: PinType(forPin: pin), encodedVerificationString: encodedVerificationString, transaction: transaction)
                }
            }
        }.recover { error in
            guard let kbsError = error as? KBSError else {
                owsFailDebug("Unexpectedly surfacing a non KBS error: \(error)")
                throw error
            }

            throw kbsError
        }
    }

    @objc(deleteKeys)
    static func objc_deleteKeys() -> AnyPromise {
        return AnyPromise(deleteKeys())
    }

    /// Remove the keys locally from the device and from the KBS,
    /// they will not be able to be restored.
    public static func deleteKeys() -> Promise<Void> {
        return deleteKeyRequest().ensure {
            // Even if the request to delete our keys from KBS failed,
            // purge them from the database.
            databaseStorage.write { clearKeys(transaction: $0) }
        }.done { _ in
            // The next token is no longer valid, as it pertains to
            // a deleted backup. Clear it out so we fetch a fresh one.
            Token.clearNext()
        }
    }

    // PRAGMA MARK: - Master Key Encryption

    public enum DerivedKey: Hashable {
        case registrationLock
        case storageService

        case storageServiceManifest(version: UInt64)
        case storageServiceRecord(identifier: StorageService.StorageIdentifier)

        var rawValue: String {
            switch self {
            case .registrationLock:
                return "Registration Lock"
            case .storageService:
                return "Storage Service Encryption"
            case .storageServiceManifest(let version):
                return "Manifest_\(version)"
            case .storageServiceRecord(let identifier):
                return "Item_\(identifier.data.base64EncodedString())"
            }
        }

        static var syncableKeys: [DerivedKey] {
            return [
                .storageService
            ]
        }

        private var dataToDeriveFrom: Data? {
            switch self {
            case .storageServiceManifest, .storageServiceRecord:
                return DerivedKey.storageService.data
            default:
                // Most keys derive directly from the master key.
                // Only a few exceptions derive from another derived key.
                guard let masterKey = cacheQueue.sync(execute: { cachedMasterKey }) else { return nil }
                return masterKey
            }
        }

        public var data: Data? {
            // If we have this derived key stored in the database, use it.
            // This should only happen if we're a linked device and received
            // the derived key via a sync message, since we won't know about
            // the master key.
            if (!tsAccountManager.isPrimaryDevice || CurrentAppContext().isRunningTests),
                let cachedData = cacheQueue.sync(execute: { cachedSyncedDerivedKeys[self] }) {
                return cachedData
            }

            // TODO: Derive Storage Service Key – Delete this.
            // This key is *only* used for storage service backup / restore.
            // It is sync'd with your linked devices, but is never stored on
            // our servers. Eventually, we'll switch storage service over to
            // using a key derived from the KBS master key so that the data
            // we backup can be restored across re-installs. At that point in
            // time we will need to delete this line which will in turn trigger
            // a re-encrypt and re-upload all the records in the storage service.
            if case .storageService = self, let storageServiceKey = cacheQueue.sync(execute: { cachedStorageServiceKey }) {
                return storageServiceKey
            }

            guard let dataToDeriveFrom = dataToDeriveFrom else {
                return nil
            }

            guard let data = rawValue.data(using: .utf8) else {
                owsFailDebug("Failed to encode data")
                return nil
            }

            return Cryptography.computeSHA256HMAC(data, withHMACKey: dataToDeriveFrom)
        }

        public var isAvailable: Bool { return data != nil }
    }

    public static func encrypt(keyType: DerivedKey, data: Data) throws -> Data {
        guard let keyData = keyType.data, let key = OWSAES256Key(data: keyData) else {
            owsFailDebug("missing derived key \(keyType)")
            throw KBSError.assertion
        }

        guard let encryptedData = Cryptography.encryptAESGCMWithDataAndConcatenateResults(
            plainTextData: data,
            initializationVectorLength: kAESGCM256_DefaultIVLength,
            key: key
        ) else {
            owsFailDebug("Failed to encrypt data")
            throw KBSError.assertion
        }

        return encryptedData
    }

    public static func decrypt(keyType: DerivedKey, encryptedData: Data) throws -> Data {
        guard let keyData = keyType.data, let key = OWSAES256Key(data: keyData) else {
            owsFailDebug("missing derived key \(keyType)")
            throw KBSError.assertion
        }

        guard let data = Cryptography.decryptAESGCMConcatenatedData(
            encryptedData: encryptedData,
            initializationVectorLength: kAESGCM256_DefaultIVLength,
            key: key
        ) else {
            // TODO: Derive Storage Service Key - until we use the restored key for storage service,
            // this is expected after every reinstall. After that this should propably become an owsFailDebug
            Logger.info("failed to decrypt data")
            throw KBSError.assertion
        }

        return data
    }

    @objc
    static func deriveRegistrationLockToken() -> String? {
        return DerivedKey.registrationLock.data?.hexadecimalString
    }

    // PRAGMA MARK: - Master Key Management

    private static func assertIsOnBackgroundQueue() {
        guard !CurrentAppContext().isRunningTests else { return }
        assertOnQueue(DispatchQueue.global())
    }

    static func deriveEncryptionKeyAndAccessKey(pin: String, backupId: Data) throws -> (encryptionKey: Data, accessKey: Data) {
        assertIsOnBackgroundQueue()

        guard let pinData = normalizePin(pin).data(using: .utf8) else { throw KBSError.assertion }
        guard backupId.count == 32 else { throw KBSError.assertion }

        let (rawHash, _) = try Argon2.hash(
            iterations: 32,
            memoryInKiB: 1024 * 16, // 16MiB
            threads: 1,
            password: pinData,
            salt: backupId,
            desiredLength: 64,
            variant: .id,
            version: .v13
        )

        return (encryptionKey: rawHash[0...31], accessKey: rawHash[32...63])
    }

    static func deriveEncodedVerificationString(pin: String, salt: Data = Cryptography.generateRandomBytes(16)) throws -> String {
        assertIsOnBackgroundQueue()

        guard let pinData = normalizePin(pin).data(using: .utf8) else { throw KBSError.assertion }
        guard salt.count == 16 else { throw KBSError.assertion }

        let (_, encodedString) = try Argon2.hash(
            iterations: 64,
            memoryInKiB: 512,
            threads: 1,
            password: pinData,
            salt: salt,
            desiredLength: 32,
            variant: .i,
            version: .v13
        )

        return encodedString
    }

    static func normalizePin(_ pin: String) -> String {
        // Trim leading and trailing whitespace
        var normalizedPin = pin.ows_stripped()

        // If this pin contains only numerals, ensure they are arabic numerals.
        if pin.digitsOnly() == normalizedPin { normalizedPin = normalizedPin.ensureArabicNumerals }

        // NFKD unicode normalization.
        return normalizedPin.decomposedStringWithCompatibilityMapping
    }

    static func generateMasterKey() -> Data {
        assertIsOnBackgroundQueue()

        return Cryptography.generateRandomBytes(32)
    }

    static func encryptMasterKey(_ masterKey: Data, encryptionKey: Data) throws -> Data {
        assertIsOnBackgroundQueue()

        guard masterKey.count == 32 else { throw KBSError.assertion }
        guard encryptionKey.count == 32 else { throw KBSError.assertion }

        let (iv, cipherText) = try Cryptography.encryptSHA256HMACSIV(data: masterKey, key: encryptionKey)

        guard iv.count == 16 else { throw KBSError.assertion }
        guard cipherText.count == 32 else { throw KBSError.assertion }

        return iv + cipherText
    }

    static func decryptMasterKey(_ ivAndCipher: Data, encryptionKey: Data) throws -> Data {
        assertIsOnBackgroundQueue()

        guard ivAndCipher.count == 48 else { throw KBSError.assertion }

        let masterKey = try Cryptography.decryptSHA256HMACSIV(
            iv: ivAndCipher[0...15],
            cipherText: ivAndCipher[16...47],
            key: encryptionKey
        )

        guard masterKey.count == 32 else { throw KBSError.assertion }

        return masterKey
    }

    // PRAGMA MARK: - Storage

    public static var keyValueStore: SDSKeyValueStore {
        return SDSKeyValueStore(collection: "kOWSKeyBackupService_Keys")
    }

    private static let masterKeyIdentifer = "masterKey"
    private static let storageServiceKeyIdentifer = "storageServiceKey"
    private static let pinTypeIdentifier = "pinType"
    private static let encodedVerificationStringIdentifier = "encodedVerificationString"
    private static let hasBackupKeyRequestFailedIdentifier = "hasBackupKeyRequestFailed"
    private static let cacheQueue = DispatchQueue(label: "org.signal.KeyBackupService")

    @objc
    public static func warmCaches() {
        var masterKey: Data?
        var storageServiceKey: Data?
        var pinType: PinType?
        var encodedVerificationString: String?

        var syncedDerivedKeys = [DerivedKey: Data]()

        databaseStorage.read { transaction in
            masterKey = keyValueStore.getData(masterKeyIdentifer, transaction: transaction)
            if let rawPinType = keyValueStore.getInt(pinTypeIdentifier, transaction: transaction) {
                pinType = PinType(rawValue: rawPinType)
            }
            encodedVerificationString = keyValueStore.getString(encodedVerificationStringIdentifier, transaction: transaction)

            for type in DerivedKey.syncableKeys {
                syncedDerivedKeys[type] = keyValueStore.getData(type.rawValue, transaction: transaction)
            }

            if tsAccountManager.isRegisteredPrimaryDevice {
                storageServiceKey = keyValueStore.getData(storageServiceKeyIdentifer, transaction: transaction)
            }
        }

        // TODO: Derive Storage Service Key – Delete this.
        // For now, if we don't have a storage service key, create one.
        // Eventually this will be derived from the master key and not
        // its own independent key.
        if tsAccountManager.isRegisteredPrimaryDevice && storageServiceKey == nil {
            storageServiceKey = Cryptography.generateRandomBytes(32)
            databaseStorage.write { transaction in
                keyValueStore.setData(storageServiceKey, key: storageServiceKeyIdentifer, transaction: transaction)
            }
        }

        cacheQueue.sync {
            cachedMasterKey = masterKey
            cachedStorageServiceKey = storageServiceKey
            cachedPinType = pinType
            cachedEncodedVerificationString = encodedVerificationString
            cachedSyncedDerivedKeys = syncedDerivedKeys
        }
    }

    /// Removes the KBS keys locally from the device, they can still be
    /// restored from the server if you know the pin.
    @objc
    public static func clearKeys(transaction: SDSAnyWriteTransaction) {
        // Delete everything but the storageServiceKey, which is persistent.
        // TODO: Derive Storage Service Key – When we migrate to deriving the storage
        // service key from the KBS master key, this should be updated to "removeAll"
        keyValueStore.removeValues(
            forKeys: [
                masterKeyIdentifer,
                pinTypeIdentifier,
                encodedVerificationStringIdentifier
            ] + DerivedKey.syncableKeys.map { $0.rawValue },
            transaction: transaction
        )
        cacheQueue.sync {
            cachedMasterKey = nil
            cachedPinType = nil
            cachedEncodedVerificationString = nil
            cachedSyncedDerivedKeys = [:]
        }
    }

    // Should only be interacted with on the serial cache queue
    // Always contains an in memory reference to our current masterKey
    private static var cachedMasterKey: Data?
    // Should only be interacted with on the serial cache queue
    // Always contains an in memory reference to our current storageServiceKey
    // TODO: Derive Storage Service Key – Delete this
    private static var cachedStorageServiceKey: Data?
    // Always contains an in memory reference to our current PIN's type
    private static var cachedPinType: PinType?
    // Always contains an in memory reference to our encoded PIN verification string
    private static var cachedEncodedVerificationString: String?
    // Always contains an in memory reference to our received derived keys
    static var cachedSyncedDerivedKeys = [DerivedKey: Data]()

    static func store(_ masterKey: Data, pinType: PinType, encodedVerificationString: String, transaction: SDSAnyWriteTransaction) {
        var previousMasterKey: Data?
        var previousPinType: PinType?
        var previousEncodedVerificationString: String?

        cacheQueue.sync {
            previousMasterKey = cachedMasterKey
            previousPinType = cachedPinType
            previousEncodedVerificationString = cachedEncodedVerificationString
        }

        guard masterKey != previousMasterKey
            || pinType != previousPinType
            || encodedVerificationString != previousEncodedVerificationString else { return }

        keyValueStore.setData(masterKey, key: masterKeyIdentifer, transaction: transaction)
        keyValueStore.setInt(pinType.rawValue, key: pinTypeIdentifier, transaction: transaction)
        keyValueStore.setString(encodedVerificationString, key: encodedVerificationStringIdentifier, transaction: transaction)
        keyValueStore.setBool(false, key: hasBackupKeyRequestFailedIdentifier, transaction: transaction)

        cacheQueue.sync {
            cachedMasterKey = masterKey
            cachedPinType = pinType
            cachedEncodedVerificationString = encodedVerificationString
        }

        // Only continue if we didn't previously have a master key or our master key has changed
        guard masterKey != previousMasterKey, tsAccountManager.isRegisteredAndReady else { return }

        // Trigger a re-creation of the storage manifest, our keys have changed
        storageServiceManager.restoreOrCreateManifestIfNecessary()

        // Sync our new keys with linked devices.
        syncManager.sendKeysSyncMessage()
    }

    // TODO: Derive Storage Service Key – Delete this
    public static func rotateStorageServiceKey(transaction: SDSAnyWriteTransaction) {
        Logger.info("")

        guard tsAccountManager.isRegisteredPrimaryDevice else {
            // Linked devices should never have a dedicated storageServiceKey, but we were
            // incorrectly creating them briefly.
            keyValueStore.setData(nil, key: storageServiceKeyIdentifer, transaction: transaction)
            cacheQueue.sync { cachedStorageServiceKey = nil }
            return
        }

        let newStorageServiceKey = Cryptography.generateRandomBytes(32)
        cacheQueue.sync { cachedStorageServiceKey = newStorageServiceKey }
        keyValueStore.setData(newStorageServiceKey, key: storageServiceKeyIdentifer, transaction: transaction)

        guard tsAccountManager.isRegisteredAndReady && AppReadiness.isAppReady() else { return }

        storageServiceManager.restoreOrCreateManifestIfNecessary()
        syncManager.sendKeysSyncMessage()
    }

    public static func storeSyncedKey(type: DerivedKey, data: Data?, transaction: SDSAnyWriteTransaction) {
        guard !tsAccountManager.isPrimaryDevice || CurrentAppContext().isRunningTests else {
            return owsFailDebug("primary device should never store synced keys")
        }

        guard DerivedKey.syncableKeys.contains(type) else {
            return owsFailDebug("tried to store a non-syncable key")
        }

        keyValueStore.setData(data, key: type.rawValue, transaction: transaction)
        cacheQueue.sync { cachedSyncedDerivedKeys[type] = data }

        // Trigger a re-fetch of the storage manifest, our keys have changed
        if type == .storageService, data != nil {
            storageServiceManager.restoreOrCreateManifestIfNecessary()
        }
    }

    // PRAGMA MARK: - Requests

    private static func enclaveRequest<RequestType: KBSRequestOption>(
        with auth: RemoteAttestationAuth? = nil,
        and requestOptionBuilder: @escaping (Token) throws -> RequestType
    ) -> Promise<RequestType.ResponseOptionType> {
        return RemoteAttestation.performForKeyBackup(auth: auth).then { remoteAttestation in
            fetchToken(for: remoteAttestation).map { ($0, remoteAttestation) }
        }.map(on: DispatchQueue.global()) { tokenResponse, remoteAttestation -> (TSRequest, RemoteAttestation) in
            let requestOption = try requestOptionBuilder(tokenResponse)
            let requestBuilder = KeyBackupProtoRequest.builder()
            requestOption.set(on: requestBuilder)
            let kbRequestData = try requestBuilder.buildSerializedData()

            guard let encryptionResult = Cryptography.encryptAESGCM(
                plainTextData: kbRequestData,
                initializationVectorLength: kAESGCM256_DefaultIVLength,
                additionalAuthenticatedData: remoteAttestation.requestId,
                key: remoteAttestation.keys.clientKey
            ) else {
                owsFailDebug("Failed to encrypt request data")
                throw KBSError.assertion
            }

            let request = OWSRequestFactory.kbsEnclaveRequest(
                withRequestId: remoteAttestation.requestId,
                data: encryptionResult.ciphertext,
                cryptIv: encryptionResult.initializationVector,
                cryptMac: encryptionResult.authTag,
                enclaveName: remoteAttestation.enclaveName,
                authUsername: remoteAttestation.auth.username,
                authPassword: remoteAttestation.auth.password,
                cookies: remoteAttestation.cookies,
                requestType: RequestType.stringRepresentation
            )

            return (request, remoteAttestation)
        }.then { request, remoteAttestation in
            networkManager.makePromise(request: request).map { ($0.responseObject, remoteAttestation) }
        }.map(on: DispatchQueue.global()) { responseObject, remoteAttestation in
            guard let parser = ParamParser(responseObject: responseObject) else {
                owsFailDebug("Failed to parse response object")
                throw KBSError.assertion
            }

            let data = try parser.requiredBase64EncodedData(key: "data")
            guard data.count > 0 else {
                owsFailDebug("data is invalid")
                throw KBSError.assertion
            }

            let iv = try parser.requiredBase64EncodedData(key: "iv")
            guard iv.count == 12 else {
                owsFailDebug("iv is invalid")
                throw KBSError.assertion
            }

            let mac = try parser.requiredBase64EncodedData(key: "mac")
            guard mac.count == 16 else {
                owsFailDebug("mac is invalid")
                throw KBSError.assertion
            }

            guard let encryptionResult = Cryptography.decryptAESGCM(
                withInitializationVector: iv,
                ciphertext: data,
                additionalAuthenticatedData: nil,
                authTag: mac,
                key: remoteAttestation.keys.serverKey
            ) else {
                owsFailDebug("failed to decrypt KBS response")
                throw KBSError.assertion
            }

            let kbResponse = try KeyBackupProtoResponse.parseData(encryptionResult)

            guard let typedResponse = RequestType.responseOption(from: kbResponse) else {
                owsFailDebug("missing KBS response object")
                throw KBSError.assertion
            }

            return typedResponse
        }
    }

    private static func backupKeyRequest(accessKey: Data, encryptedMasterKey: Data, and auth: RemoteAttestationAuth? = nil) -> Promise<KeyBackupProtoBackupResponse> {
        return enclaveRequest(with: auth) { token -> KeyBackupProtoBackupRequest in
            guard let serviceId = Data.data(fromHex: TSConstants.keyBackupServiceId) else {
                owsFailDebug("failed to encode service id")
                throw KBSError.assertion
            }

            let backupRequestBuilder = KeyBackupProtoBackupRequest.builder()
            backupRequestBuilder.setData(encryptedMasterKey)
            backupRequestBuilder.setPin(accessKey)
            backupRequestBuilder.setToken(token.data)
            backupRequestBuilder.setBackupID(token.backupId)
            backupRequestBuilder.setTries(maximumKeyAttempts)
            backupRequestBuilder.setServiceID(serviceId)

            // number of seconds since unix epoch after which this request should be valid
            // Always set to the client's clock time, minus 24 hours to account for inaccurate clocks
            backupRequestBuilder.setValidFrom(UInt64(Date().addingTimeInterval(-kDayInterval).timeIntervalSince1970))

            do {
                return try backupRequestBuilder.build()
            } catch {
                owsFailDebug("failed to build backup request")
                throw KBSError.assertion
            }
        }
    }

    private static func restoreKeyRequest(accessKey: Data, with auth: RemoteAttestationAuth? = nil) -> Promise<KeyBackupProtoRestoreResponse> {
        return enclaveRequest(with: auth) { token -> KeyBackupProtoRestoreRequest in
            guard let serviceId = Data.data(fromHex: TSConstants.keyBackupServiceId) else {
                owsFailDebug("failed to encode service id")
                throw KBSError.assertion
            }

            let restoreRequestBuilder = KeyBackupProtoRestoreRequest.builder()
            restoreRequestBuilder.setPin(accessKey)
            restoreRequestBuilder.setToken(token.data)
            restoreRequestBuilder.setBackupID(token.backupId)
            restoreRequestBuilder.setServiceID(serviceId)

            // number of seconds since unix epoch after which this request should be valid
            // Always set to the client's clock time, minus 24 hours to account for inaccurate clocks
            restoreRequestBuilder.setValidFrom(UInt64(Date().addingTimeInterval(-kDayInterval).timeIntervalSince1970))

            do {
                return try restoreRequestBuilder.build()
            } catch {
                owsFailDebug("failed to build restore request")
                throw KBSError.assertion
            }
        }
    }

    private static func deleteKeyRequest() -> Promise<KeyBackupProtoDeleteResponse> {
        return enclaveRequest { token -> KeyBackupProtoDeleteRequest in
            guard let serviceId = Data.data(fromHex: TSConstants.keyBackupServiceId) else {
                owsFailDebug("failed to encode service id")
                throw KBSError.assertion
            }

            let deleteRequestBuilder = KeyBackupProtoDeleteRequest.builder()
            deleteRequestBuilder.setBackupID(token.backupId)
            deleteRequestBuilder.setServiceID(serviceId)

            do {
                return try deleteRequestBuilder.build()
            } catch {
                owsFailDebug("failed to build delete request")
                throw KBSError.assertion
            }
        }
    }

    public static func hasBackupKeyRequestFailed(transaction: SDSAnyReadTransaction) -> Bool {
        keyValueStore.getBool(hasBackupKeyRequestFailedIdentifier, defaultValue: false, transaction: transaction)
    }

    // PRAGMA MARK: - Token

    public static var tokenStore: SDSKeyValueStore {
        return SDSKeyValueStore(collection: "kOWSKeyBackupService_Token")
    }

    private struct Token {
        private static var keyValueStore: SDSKeyValueStore {
            return KeyBackupService.tokenStore
        }

        private static let backupIdKey = "backupIdKey"
        private static let dataKey = "dataKey"
        private static let triesKey = "triesKey"

        let backupId: Data
        let data: Data
        let tries: UInt32

        private init(backupId: Data, data: Data, tries: UInt32) throws {
            guard backupId.count == 32 else {
                owsFailDebug("invalid backupId")
                throw KBSError.assertion
            }
            self.backupId = backupId

            guard data.count == 32 else {
                owsFailDebug("invalid token data")
                throw KBSError.assertion
            }
            self.data = data

            self.tries = tries
        }

        /// Update the token to use for the next enclave request.
        /// If backupId or tries are nil, attempts to use the previously known value.
        /// If we don't have a cached value (we've never stored a token before), an error is thrown.
        @discardableResult
        static func updateNext(backupId: Data? = nil, data: Data, tries: UInt32? = nil) throws -> Token {
            guard let backupId = backupId ?? databaseStorage.read(block: { transaction in
                keyValueStore.getData(backupIdKey, transaction: transaction)
            }) else {
                owsFailDebug("missing backupId")
                throw KBSError.assertion
            }

            guard let tries = tries ?? databaseStorage.read(block: { transaction in
                keyValueStore.getUInt32(triesKey, transaction: transaction)
            }) else {
                owsFailDebug("missing tries")
                throw KBSError.assertion
            }

            let token = try Token(backupId: backupId, data: data, tries: tries)
            token.recordAsCurrent()
            return token
        }

        /// Update the token to use for the next enclave request.
        @discardableResult
        static func updateNext(responseObject: Any?) throws -> Token {
            guard let paramParser = ParamParser(responseObject: responseObject) else {
                owsFailDebug("Unexpectedly missing response object")
                throw KBSError.assertion
            }

            let backupId = try paramParser.requiredBase64EncodedData(key: "backupId")
            let data = try paramParser.requiredBase64EncodedData(key: "token")
            let tries: UInt32 = try paramParser.required(key: "tries")

            let token = try Token(backupId: backupId, data: data, tries: tries)
            token.recordAsCurrent()
            return token
        }

        static func clearNext() {
            databaseStorage.write { transaction in
                keyValueStore.setData(nil, key: backupIdKey, transaction: transaction)
                keyValueStore.setData(nil, key: dataKey, transaction: transaction)
                keyValueStore.setObject(nil, key: triesKey, transaction: transaction)
            }
        }

        /// The token to use when making the next enclave request.
        static var next: Token? {
            return databaseStorage.read { transaction in
                guard let backupId = keyValueStore.getData(backupIdKey, transaction: transaction),
                    let data = keyValueStore.getData(dataKey, transaction: transaction),
                    let tries = keyValueStore.getUInt32(triesKey, transaction: transaction) else {
                        return nil
                }

                do {
                    return try Token(backupId: backupId, data: data, tries: tries)
                } catch {
                    // This should never happen, but if for some reason our stored token gets
                    // corrupted we'll return nil which will trigger us to fetch a fresh one
                    // from the enclave.
                    owsFailDebug("unexpectedly failed to initialize token with error: \(error)")
                    return nil
                }
            }
        }

        private func recordAsCurrent() {
            databaseStorage.write { transaction in
                Token.keyValueStore.setData(self.backupId, key: Token.backupIdKey, transaction: transaction)
                Token.keyValueStore.setData(self.data, key: Token.dataKey, transaction: transaction)
                Token.keyValueStore.setUInt32(self.tries, key: Token.triesKey, transaction: transaction)
            }
        }
    }

    private static func fetchBackupId(auth: RemoteAttestationAuth?) -> Promise<Data> {
        if let currentToken = Token.next { return Promise.value(currentToken.backupId) }

        return RemoteAttestation.performForKeyBackup(auth: auth).then { remoteAttestation in
            fetchToken(for: remoteAttestation).map { $0.backupId }
        }
    }

    private static func fetchToken(for remoteAttestation: RemoteAttestation) -> Promise<Token> {
        // If we already have a token stored, we need to use it before fetching another.
        // We only stop using this token once the enclave informs us it is spent.
        if let currentToken = Token.next { return Promise.value(currentToken) }

        // Fetch a new token

        let request = OWSRequestFactory.kbsEnclaveTokenRequest(
            withEnclaveName: remoteAttestation.enclaveName,
            authUsername: remoteAttestation.auth.username,
            authPassword: remoteAttestation.auth.password,
            cookies: remoteAttestation.cookies
        )

        return networkManager.makePromise(request: request).map(on: DispatchQueue.global()) { _, responseObject in
            try Token.updateNext(responseObject: responseObject)
        }
    }
}
// PRAGMA MARK: -

private protocol KBSRequestOption {
    associatedtype ResponseOptionType
    static func responseOption(from response: KeyBackupProtoResponse) -> ResponseOptionType?
    func set(on builder: KeyBackupProtoRequest.KeyBackupProtoRequestBuilder)

    static var stringRepresentation: String { get }
}

extension KeyBackupProtoBackupRequest: KBSRequestOption {
    typealias ResponseOptionType = KeyBackupProtoBackupResponse
    static func responseOption(from response: KeyBackupProtoResponse) -> ResponseOptionType? {
        return response.backup
    }
    func set(on builder: KeyBackupProtoRequest.KeyBackupProtoRequestBuilder) {
        builder.setBackup(self)
    }
    static var stringRepresentation: String { "backup" }
}
extension KeyBackupProtoRestoreRequest: KBSRequestOption {
    typealias ResponseOptionType = KeyBackupProtoRestoreResponse
    static func responseOption(from response: KeyBackupProtoResponse) -> ResponseOptionType? {
        return response.restore
    }
    func set(on builder: KeyBackupProtoRequest.KeyBackupProtoRequestBuilder) {
        builder.setRestore(self)
    }
    static var stringRepresentation: String { "restore" }
}
extension KeyBackupProtoDeleteRequest: KBSRequestOption {
    typealias ResponseOptionType = KeyBackupProtoDeleteResponse
    static func responseOption(from response: KeyBackupProtoResponse) -> ResponseOptionType? {
        return response.delete
    }
    func set(on builder: KeyBackupProtoRequest.KeyBackupProtoRequestBuilder) {
        builder.setDelete(self)
    }
    static var stringRepresentation: String { "delete" }
}
