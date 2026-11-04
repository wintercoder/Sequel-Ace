import Foundation

/// A value snapshot: exporting never changes favorites or Keychain entries.
struct SAJSONExportConnection {
    let favorite: NSDictionary
    let groupPath: [String]
}

enum SAJSONFavoritesExport {
    // Standard TCP/IP options that must survive a JSON round trip.
    static let optionKeys: Set<String> = [
        "useSSL", "sslKeyFileLocationEnabled", "sslKeyFileLocation",
        "sslCertificateFileLocationEnabled", "sslCertificateFileLocation",
        "sslCACertFileLocationEnabled", "sslCACertFileLocation", "useCompression",
        "timeZoneMode", "timeZone", "allowDataLocalInfile", "enableClearTextPlugin",
        "requestServerPublicKey", "colorIndex"
    ]

    static func data(connections: [SAJSONExportConnection], keychain: SAKeychainProviding) throws -> Data {
        guard !connections.isEmpty else { throw failure() }
        // Validate all connections before asking the Keychain for any passwords.
        for connection in connections {
            let rawType = connection.favorite["type"]
            let type = (rawType as? NSNumber)?.intValue ?? (rawType as? NSString)?.integerValue ?? 0
            guard type == 0,
                  connection.groupPath.count <= 2 else { throw failure() }
        }
        var records: [[String: Any]] = []
        for connection in connections {
            let favorite = connection.favorite
            var record: [String: Any] = [:]
            for key in ["name", "host", "port", "user", "database"] {
                let value = favorite[key] ?? ""
                record[key.prefix(1).uppercased() + key.dropFirst()] = value
            }
            if (record["Port"] as? String)?.isEmpty == true { record["Port"] = "3306" }
            for (index, folder) in connection.groupPath.enumerated() { record["level\(index + 1)"] = folder }
            var options: [String: Any] = [:]
            for key in optionKeys { if let value = favorite[key] { options[key] = value } }
            if !options.isEmpty { record["Options"] = options }
            records.append(record)
        }
        // Reuse the import validator to reject malformed saved details, without
        // leaking any password into validation diagnostics.
        let validationData = try JSONSerialization.data(withJSONObject: records)
        _ = try SAJSONFavorites.favorites(from: validationData)
        for index in records.indices {
            let favorite = connections[index].favorite
            let name = keychain.name(favoriteName: favorite["name"] as? String, id: favorite["id"])
            let account = keychain.account(user: favorite["user"] as? String,
                                           host: favorite["host"] as? String,
                                           database: favorite["database"] as? String ?? "")
            // nil means no retrievable saved password. Leave the field absent;
            // an actual empty password is exported as an explicit empty string.
            if let password = keychain.password(name: name, account: account) { records[index]["Password"] = password }
        }
        return try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
    }

    private static func failure() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
                    "JSON export supports standard TCP/IP connections in up to two folder levels. Use plist export for other connection types or deeper folders.",
                    comment: "Unsupported connection type or folder depth in JSON export")])
    }
}
