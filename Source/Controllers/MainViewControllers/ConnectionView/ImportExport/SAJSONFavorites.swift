import Foundation
import CoreFoundation

/// JSON credentials remain transient until the user accepts the import.
@objc final class SAJSONFavorites: NSObject {
    static let maxGroupDepth = 5

    @objc(favoritesFromData:error:)
    static func favorites(from data: Data) throws -> [NSMutableDictionary] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            // JSONSerialization's diagnostic can contain fragments of a password.
            throw invalidFile()
        }
        let records: [Any]
        if let array = root as? [Any] {
            records = array
        } else if let object = root as? [String: Any] {
            if let array = object["Connections"] as? [Any] ?? object["connections"] as? [Any] {
                records = array
            } else {
                records = [object]
            }
        } else {
            throw invalidFile()
        }
        guard !records.isEmpty else { throw invalidFile() }
        // Validate the whole file before any favorites or Keychain entries change.
        return try records.enumerated().map { index, record in
            guard let object = record as? [String: Any] else { throw invalidFile(index + 1) }
            var fields: [String: Any] = [:]
            for (key, value) in object {
                let normalized = key.lowercased()
                guard fields[normalized] == nil else { throw invalidFile(index + 1) }
                fields[normalized] = value
            }
            func string(_ key: String, required: Bool = false) throws -> String {
                guard let value = fields[key] else {
                    if required { throw invalidFile(index + 1) }
                    return ""
                }
                guard let text = value as? String,
                      !required || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw invalidFile(index + 1)
                }
                return text
            }
            let name = try string("name", required: true)
            let host = try string("host", required: true)
            let user = try string("user", required: true)
            var port = "3306"
            if let value = fields["port"] {
                if let text = value as? String {
                    port = text
                } else if let number = value as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue == Double(number.intValue) {
                    port = number.stringValue
                } else {
                    throw invalidFile(index + 1)
                }
                guard let number = Int(port), (1...65535).contains(number) else { throw invalidFile(index + 1) }
                port = String(number)
            }
            // Folder levels must form a contiguous path; never flatten a gap.
            var groupPath: [String] = []
            for level in 1...maxGroupDepth {
                let folder = try string("level\(level)")
                if folder.isEmpty { continue }
                guard groupPath.count == level - 1,
                      !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw invalidFile(index + 1)
                }
                groupPath.append(folder)
            }
            guard !fields.keys.contains(where: {
                $0.hasPrefix("level") && (Int($0.dropFirst(5)) ?? 0) > maxGroupDepth
            }) else {
                throw invalidFile(index + 1)
            }
            // Keep in sync with SPConstants.m: passwords are NOT persisted favorite keys.
            let favorite = NSMutableDictionary(dictionary: [
                "name": name, "host": host, "user": user, "port": port,
                "database": try string("database"), "type": 0, "colorIndex": -1
            ])
            if let rawOptions = fields["options"] {
                guard let options = rawOptions as? [String: Any] else { throw invalidFile(index + 1) }
                for (key, value) in options {
                    guard SAJSONFavoritesExport.optionKeys.contains(key),
                          value is String || value is NSNumber else { throw invalidFile(index + 1) }
                    favorite[key] = value
                }
            }
            if fields["password"] != nil { favorite["password"] = try string("password") }
            favorite["_saJSONGroupPath"] = groupPath
            return favorite
        }
    }

    private static func invalidFile(_ row: Int = 0) -> NSError {
        let message = row == 0
            ? NSLocalizedString("Invalid JSON connection file. Expected a connection object, an array, or a Connections array.", comment: "JSON favorites import format error")
            : String(format: NSLocalizedString("Invalid JSON connection at position %ld. Name, Host and User must be nonempty strings; Password, Database and level1 through level5 must be strings; folder levels must be consecutive and cannot exceed five; Port must be between 1 and 65535.", comment: "JSON favorites import validation error; position only, never credential values"), row)
        return NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Remove credentials before the dictionaries reach the favorites tree or duplicate UI.
/// A context belongs to one import, including its asynchronous duplicate sheet.
@objc final class SAJSONImportCredentials: NSObject {
    private var groupPaths: [String: [String]] = [:]
    private var passwords: [String: String] = [:]

    @objc(initWithItems:)
    init(items: [NSMutableDictionary]) {
        super.init()
        for item in items { extract(from: item) }
    }

    private func extract(from item: NSMutableDictionary) {
        if let children = item["Children"] as? [NSMutableDictionary] {
            for child in children { extract(from: child) }
        }
        if let password = item["password"] as? String, let id = item["id"] as? NSNumber {
            passwords[id.stringValue] = password
        }
        if let path = item["_saJSONGroupPath"] as? [String], let id = item["id"] as? NSNumber {
            groupPaths[id.stringValue] = path
        }
        item.removeObject(forKey: "_saJSONGroupPath")
        item.removeObject(forKey: "password")
    }

    @objc(groupPathForFavorite:)
    func groupPath(for favorite: NSDictionary) -> [String] {
        guard let id = favorite["id"] as? NSNumber else { return [] }
        return groupPaths[id.stringValue] ?? []
    }

    @objc(savePasswordForFavorite:importedFavorite:keychain:)
    func savePassword(for favorite: NSDictionary, importedFavorite: NSDictionary, keychain: SAKeychainProviding) {
        guard let password = password(for: importedFavorite) else { return }
        let name = keychain.name(favoriteName: favorite["name"] as? String, id: favorite["id"])
        let account = keychain.account(user: favorite["user"] as? String,
                                      host: favorite["host"] as? String,
                                      database: favorite["database"] as? String ?? "")
        if keychain.passwordExists(name: name, account: account) {
            keychain.updateItem(name: name, account: account, toName: name, newAccount: account, password: password)
        } else {
            keychain.add(password: password, name: name, account: account)
        }
    }

    @objc(passwordForFavorite:)
    func password(for favorite: NSDictionary) -> String? {
        guard let id = favorite["id"] as? NSNumber else { return nil }
        return passwords[id.stringValue]
    }
}
import Foundation
import CoreFoundation

/// JSON credentials remain transient until the user accepts the import.
@objc final class SAJSONFavorites: NSObject {
    @objc(favoritesFromData:error:)
    static func favorites(from data: Data) throws -> [NSMutableDictionary] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            // JSONSerialization's diagnostic can contain fragments of a password.
            throw invalidFile()
        }
        let records: [Any]
        if let array = root as? [Any] {
            records = array
        } else if let object = root as? [String: Any] {
            if let array = object["Connections"] as? [Any] ?? object["connections"] as? [Any] {
                records = array
            } else {
                records = [object]
            }
        } else {
            throw invalidFile()
        }
        guard !records.isEmpty else { throw invalidFile() }
        // Validate the whole file before any favorites or Keychain entries change.
        return try records.enumerated().map { index, record in
            guard let object = record as? [String: Any] else { throw invalidFile(index + 1) }
            var fields: [String: Any] = [:]
            for (key, value) in object {
                let normalized = key.lowercased()
                guard fields[normalized] == nil else { throw invalidFile(index + 1) }
                fields[normalized] = value
            }
            func string(_ key: String, required: Bool = false) throws -> String {
                guard let value = fields[key] else {
                    if required { throw invalidFile(index + 1) }
                    return ""
                }
                guard let text = value as? String,
                      !required || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw invalidFile(index + 1)
                }
                return text
            }
            let name = try string("name", required: true)
            let host = try string("host", required: true)
            let user = try string("user", required: true)
            var port = "3306"
            if let value = fields["port"] {
                if let text = value as? String {
                    port = text
                } else if let number = value as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue == Double(number.intValue) {
                    port = number.stringValue
                } else {
                    throw invalidFile(index + 1)
                }
                guard let number = Int(port), (1...65535).contains(number) else { throw invalidFile(index + 1) }
                port = String(number)
            }
            let level1 = try string("level1")
            let level2 = try string("level2")
            guard level2.isEmpty || !level1.isEmpty,
                  level1.isEmpty || !level1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  level2.isEmpty || !level2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalidFile(index + 1)
            }
            // Keep in sync with SPConstants.m: passwords are NOT persisted favorite keys.
            let favorite = NSMutableDictionary(dictionary: [
                "name": name, "host": host, "user": user, "port": port,
                "database": try string("database"), "type": 0, "colorIndex": -1
            ])
            if let rawOptions = fields["options"] {
                guard let options = rawOptions as? [String: Any] else { throw invalidFile(index + 1) }
                for (key, value) in options {
                    guard SAJSONFavoritesExport.optionKeys.contains(key),
                          value is String || value is NSNumber else { throw invalidFile(index + 1) }
                    favorite[key] = value
                }
            }
            if fields["password"] != nil { favorite["password"] = try string("password") }
            favorite["_saJSONGroupPath"] = [level1, level2].filter { !$0.isEmpty }
            return favorite
        }
    }

    private static func invalidFile(_ row: Int = 0) -> NSError {
        let message = row == 0
            ? NSLocalizedString("Invalid JSON connection file. Expected a connection object, an array, or a Connections array.", comment: "JSON favorites import format error")
            : String(format: NSLocalizedString("Invalid JSON connection at position %ld. Name, Host and User must be nonempty strings; Password, Database, level1 and level2 must be strings; level2 requires level1; Port must be between 1 and 65535.", comment: "JSON favorites import validation error; position only, never credential values"), row)
        return NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Remove credentials before the dictionaries reach the favorites tree or duplicate UI.
/// A context belongs to one import, including its asynchronous duplicate sheet.
@objc final class SAJSONImportCredentials: NSObject {
    private var groupPaths: [String: [String]] = [:]
    private var passwords: [String: String] = [:]

    @objc(initWithItems:)
    init(items: [NSMutableDictionary]) {
        super.init()
        for item in items { extract(from: item) }
    }

    private func extract(from item: NSMutableDictionary) {
        if let children = item["Children"] as? [NSMutableDictionary] {
            for child in children { extract(from: child) }
        }
        if let password = item["password"] as? String, let id = item["id"] as? NSNumber {
            passwords[id.stringValue] = password
        }
        if let path = item["_saJSONGroupPath"] as? [String], let id = item["id"] as? NSNumber {
            groupPaths[id.stringValue] = path
        }
        item.removeObject(forKey: "_saJSONGroupPath")
        item.removeObject(forKey: "password")
    }

    @objc(groupPathForFavorite:)
    func groupPath(for favorite: NSDictionary) -> [String] {
        guard let id = favorite["id"] as? NSNumber else { return [] }
        return groupPaths[id.stringValue] ?? []
    }

    @objc(savePasswordForFavorite:importedFavorite:keychain:)
    func savePassword(for favorite: NSDictionary, importedFavorite: NSDictionary, keychain: SAKeychainProviding) {
        guard let password = password(for: importedFavorite) else { return }
        let name = keychain.name(favoriteName: favorite["name"] as? String, id: favorite["id"])
        let account = keychain.account(user: favorite["user"] as? String,
                                      host: favorite["host"] as? String,
                                      database: favorite["database"] as? String ?? "")
        if keychain.passwordExists(name: name, account: account) {
            keychain.updateItem(name: name, account: account, toName: name, newAccount: account, password: password)
        } else {
            keychain.add(password: password, name: name, account: account)
        }
    }

    @objc(passwordForFavorite:)
    func password(for favorite: NSDictionary) -> String? {
        guard let id = favorite["id"] as? NSNumber else { return nil }
        return passwords[id.stringValue]
    }
}
