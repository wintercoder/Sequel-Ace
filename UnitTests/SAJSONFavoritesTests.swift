import XCTest

final class SAJSONFavoritesTests: XCTestCase {
    private func parse(_ json: String) throws -> [NSMutableDictionary] {
        try SAJSONFavorites.favorites(from: Data(json.utf8))
    }

    func testBatchPreservesNamesAndPasswords() throws {
        let favorites = try parse("""
        [{"Name":"First DB","Host":"localhost","User":"alice","Password":" p@ss:密码 ","Port":3307},
         {"Name":"Second DB","Host":"db.example","User":"bob","Password":"","Database":"reports"}]
        """)
        XCTAssertEqual(favorites.count, 2)
        XCTAssertEqual(favorites[0]["name"] as? String, "First DB")
        XCTAssertEqual(favorites[0]["port"] as? String, "3307")
        XCTAssertEqual(favorites[0]["password"] as? String, " p@ss:密码 ")
        XCTAssertEqual(favorites[1]["port"] as? String, "3306")
        XCTAssertEqual(favorites[1]["database"] as? String, "reports")
    }

    func testSingleAndWrappedObjects() throws {
        for json in [
            "{\"name\":\"DB\",\"host\":\"localhost\",\"user\":\"root\",\"port\":\"3306\"}",
            "{\"Connections\":[{\"Name\":\"DB\",\"Host\":\"localhost\",\"User\":\"root\"}]}"
        ] {
            XCTAssertEqual(try parse(json).first?["name"] as? String, "DB")
        }
    }

    func testRejectsInvalidRecordsWithoutLeakingValues() {
        for json in ["[]", "null", "[42]", "{\"Name\":\"secret\"}",
                     "{\"Name\":\"DB\",\"Host\":\"h\",\"User\":\"u\",\"Port\":true}",
                     "{\"Name\":\"DB\",\"Host\":\"h\",\"User\":\"u\",\"Password\":42}",
                     "{\"Name\":\"DB\",\"name\":\"other\",\"Host\":\"h\",\"User\":\"u\"}",
                     "{\"Password\":\"secret"] {
            XCTAssertThrowsError(try parse(json)) { error in
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
        for port in ["0", "65536", "1.5", "null", "\"abc\""] {
            XCTAssertThrowsError(try parse("{\"Name\":\"DB\",\"Host\":\"h\",\"User\":\"u\",\"Port\":\(port)}"))
        }
    }

    func testCredentialsRemovedBeforePersistenceAndBoundToFreshID() throws {
        let favorites = try parse("""
        [{"Name":"DB","Host":"h","User":"u","Password":"secret"},
         {"Name":"DB2","Host":"h2","User":"u","Password":""}]
        """)
        favorites[0]["id"] = NSNumber(value: 123)
        favorites[1]["id"] = NSNumber(value: 456)
        let credentials = SAJSONImportCredentials(items: favorites)
        XCTAssertEqual(credentials.password(for: favorites[0]), "secret")
        XCTAssertEqual(credentials.password(for: favorites[1]), "")
        XCTAssertNil(favorites[0]["password"])
        XCTAssertNil(favorites[1]["password"])
        let plist = try PropertyListSerialization.data(fromPropertyList: favorites, format: .xml, options: 0)
        XCTAssertFalse(String(decoding: plist, as: UTF8.self).contains("secret"))
    }
}

private final class SAJSONTestKeychain: NSObject, SAKeychainProviding {
    var reads = 0
    var stored: String?
    var savedName: String?
    func add(password: String?, name: String?, account: String?) { stored = password; savedName = name }
    func add(password: String?, name: String?, account: String?, label: String?) { add(password: password, name: name, account: account) }
    func password(name: String?, account: String?) -> String? { reads += 1; return stored }
    func deletePassword(name: String?, account: String?) { stored = nil }
    func passwordExists(name: String?, account: String?) -> Bool { stored != nil }
    func updateItem(name: String?, account: String?, toName newName: String?, newAccount: String?, password: String?) { stored = password; savedName = newName }
    func name(favoriteName: String?, id favoriteID: Any?) -> String? { "\(favoriteName ?? ""):\(favoriteID ?? "")" }
    func account(user: String?, host: String?, database: String?) -> String? { "\(user ?? "")@\(host ?? "")/\(database ?? "")" }
    func sshName(favoriteName: String?, id favoriteID: Any?) -> String? { nil }
    func sshAccount(user: String?, host: String?) -> String? { nil }
}

extension SAJSONFavoritesTests {
    func testPasswordUpdatesUseRetainedIdentityAndAllowEmptyPassword() throws {
        let favorites = try parse("""
        [{"Name":"Import","Host":"h","User":"u","Password":""}]
        """)
        favorites[0]["id"] = NSNumber(value: 123)
        let credentials = SAJSONImportCredentials(items: favorites)
        let existing: NSDictionary = ["id": NSNumber(value: 999), "name": "Existing", "host": "h", "user": "u"]
        let keychain = SAJSONTestKeychain()
        keychain.stored = "old"
        credentials.savePassword(for: existing, importedFavorite: favorites[0], keychain: keychain)
        XCTAssertEqual(keychain.stored, "")
        XCTAssertEqual(keychain.savedName, "Existing:999")
    }

    func testNewPasswordIsSavedAndMissingPasswordLeavesExistingValue() throws {
        let favorites = try parse("""
        [{"Name":"DB","Host":"h","User":"u","Password":"secret"},
         {"Name":"DB2","Host":"h","User":"u"}]
        """)
        favorites[0]["id"] = NSNumber(value: 1)
        favorites[1]["id"] = NSNumber(value: 2)
        let credentials = SAJSONImportCredentials(items: favorites)
        let keychain = SAJSONTestKeychain()
        credentials.savePassword(for: favorites[0], importedFavorite: favorites[0], keychain: keychain)
        XCTAssertEqual(keychain.stored, "secret")
        credentials.savePassword(for: favorites[1], importedFavorite: favorites[1], keychain: keychain)
        XCTAssertEqual(keychain.stored, "secret")
    }
}

extension SAJSONFavoritesTests {
    func testGroupingFieldsAreTransientAndKeepTheirOrder() throws {
        let favorites = try parse("""
        [{"Name":"DB","Host":"h","User":"u","level1":"fo","level2":"uat","Password":"secret"},
         {"Name":"DB2","Host":"h2","User":"u","Level1":"fo"},
         {"Name":"DB3","Host":"h3","User":"u"}]
        """)
        for (index, favorite) in favorites.enumerated() { favorite["id"] = NSNumber(value: index) }
        let credentials = SAJSONImportCredentials(items: favorites)
        XCTAssertEqual(credentials.groupPath(for: favorites[0]), ["fo", "uat"])
        XCTAssertEqual(credentials.groupPath(for: favorites[1]), ["fo"])
        XCTAssertEqual(credentials.groupPath(for: favorites[2]), [])
        XCTAssertNil(favorites[0]["_saJSONGroupPath"])
        XCTAssertNil(favorites[0]["password"])
        XCTAssertEqual(credentials.password(for: favorites[0]), "secret")
    }

    func testRejectsOrphanOrMalformedGroupingFields() {
        for fields in ["\"level2\":\"uat\"", "\"level1\":42", "\"level1\":\" \"", "\"level1\":null",
                       "\"level1\":\"fo\",\"level2\":false"] {
            XCTAssertThrowsError(try parse("{\"Name\":\"DB\",\"Host\":\"h\",\"User\":\"u\",\(fields)}"))
        }
    }
}

extension SAJSONFavoritesTests {
    func testPlaintextExportRoundTripsNamesFoldersPasswordsAndSSLOptions() throws {
        let original: NSDictionary = ["name":"订单库", "host":"db.example", "user":"reader", "id":1,
                                      "database":"app", "port":"3307", "type":0, "useSSL":1,
                                      "sslCACertFileLocation":"/tmp/ca.pem", "colorIndex":3]
        let keychain = SAJSONTestKeychain()
        keychain.stored = " 密码 @ : \\\n\" "
        let data = try SAJSONFavoritesExport.data(connections: [SAJSONExportConnection(favorite: original, groupPath: ["fo", "uat"])], keychain: keychain)
        let imported = try SAJSONFavorites.favorites(from: data)
        XCTAssertEqual(imported[0]["name"] as? String, "订单库")
        XCTAssertEqual(imported[0]["password"] as? String, keychain.stored)
        XCTAssertEqual(imported[0]["_saJSONGroupPath"] as? [String], ["fo", "uat"])
        XCTAssertEqual(imported[0]["port"] as? String, "3307")
        XCTAssertEqual(imported[0]["useSSL"] as? Int, 1)
        XCTAssertEqual(imported[0]["sslCACertFileLocation"] as? String, "/tmp/ca.pem")
        XCTAssertNil(original["password"])
        XCTAssertEqual(keychain.reads, 1)
    }

    func testExportDistinguishesMissingAndEmptyPasswords() throws {
        let favorite: NSDictionary = ["name":"DB", "host":"h", "user":"u", "id":1, "port":""]
        let connection = SAJSONExportConnection(favorite: favorite, groupPath: [])
        let keychain = SAJSONTestKeychain()
        let missing = try SAJSONFavoritesExport.data(connections: [connection], keychain: keychain)
        XCTAssertNil(try SAJSONFavorites.favorites(from: missing)[0]["password"])
        keychain.stored = ""
        let empty = try SAJSONFavoritesExport.data(connections: [connection], keychain: keychain)
        XCTAssertEqual(try SAJSONFavorites.favorites(from: empty)[0]["password"] as? String, "")
    }

    func testUnsupportedExportsDoNotReadPasswords() {
        let keychain = SAJSONTestKeychain()
        for type: Any in [NSNumber(value: 2), "2"] {
            let favorite: NSDictionary = ["name":"SSH", "host":"h", "user":"u", "type":type]
            XCTAssertThrowsError(try SAJSONFavoritesExport.data(connections: [SAJSONExportConnection(favorite: favorite, groupPath: [])], keychain: keychain))
        }
        let favorite: NSDictionary = ["name":"DB", "host":"h", "user":"u", "type":0]
        XCTAssertThrowsError(try SAJSONFavoritesExport.data(connections: [SAJSONExportConnection(favorite: favorite, groupPath: ["a", "b", "c", "d", "e", "f"])], keychain: keychain))
        XCTAssertEqual(keychain.reads, 0)
    }

    func testImportedOptionsCannotOverrideIdentityOrInjectCredentials() {
        for option in ["\"password\":\"secret\"", "\"id\":999", "\"type\":2", "\"useSSL\":{}"] {
            XCTAssertThrowsError(try parse("{\"Name\":\"DB\",\"Host\":\"h\",\"User\":\"u\",\"Options\":{\(option)}}"))
        }
    }
}

extension SAJSONFavoritesTests {
    func testImportsEverySupportedFolderDepth() throws {
        let path = ["staging", "id", "finance", "archive", "2026"]
        for depth in 1...5 {
            var record: [String: Any] = ["Name": "DB", "Host": "h", "User": "u", "Password": "secret"]
            for index in 0..<depth { record["Level\(index + 1)"] = path[index] }
            let favorites = try SAJSONFavorites.favorites(from: JSONSerialization.data(withJSONObject: [record]))
            favorites[0]["id"] = NSNumber(value: depth)
            let credentials = SAJSONImportCredentials(items: favorites)
            XCTAssertEqual(credentials.groupPath(for: favorites[0]), Array(path.prefix(depth)))
            XCTAssertEqual(credentials.password(for: favorites[0]), "secret")
            XCTAssertNil(favorites[0]["_saJSONGroupPath"])
        }
    }

    func testRejectsGapsAndMalformedDeeperFolderLevels() throws {
        for level in 3...5 {
            var record: [String: Any] = ["Name": "DB", "Host": "h", "User": "u"]
            for previous in 1..<level { record["level\(previous)"] = "folder\(previous)" }
            for invalid: Any in [42, true, NSNull(), " \n "] {
                record["level\(level)"] = invalid
                XCTAssertThrowsError(try SAJSONFavorites.favorites(from: JSONSerialization.data(withJSONObject: [record])))
            }
            record["level\(level)"] = "child"
            record.removeValue(forKey: "level\(level - 1)")
            XCTAssertThrowsError(try SAJSONFavorites.favorites(from: JSONSerialization.data(withJSONObject: [record])))
            record["level\(level - 1)"] = ""
            XCTAssertThrowsError(try SAJSONFavorites.favorites(from: JSONSerialization.data(withJSONObject: [record])))
        }
        XCTAssertThrowsError(try parse("{\"Name\":\"DB\",\"Host\":\"h\",\"User\":\"u\",\"level6\":\"too deep\"}"))
    }

    func testFiveLevelPlaintextExportRoundTrips() throws {
        let favorite: NSDictionary = ["name": "DB", "host": "h", "user": "u", "id": 1]
        let path = ["staging", "id", "finance", "archive", "2026"]
        let keychain = SAJSONTestKeychain()
        keychain.stored = "secret"
        let data = try SAJSONFavoritesExport.data(connections: [SAJSONExportConnection(favorite: favorite, groupPath: path)], keychain: keychain)
        let favorites = try SAJSONFavorites.favorites(from: data)
        XCTAssertEqual(favorites[0]["_saJSONGroupPath"] as? [String], path)
        XCTAssertEqual(favorites[0]["password"] as? String, "secret")
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(records[0]["level5"] as? String, "2026")
        XCTAssertNil(records[0]["level6"])
    }
}
import XCTest

final class SAJSONFavoritesTests: XCTestCase {
    private func parse(_ json: String) throws -> [NSMutableDictionary] {
        try SAJSONFavorites.favorites(from: Data(json.utf8))
    }

    func testBatchPreservesNamesAndPasswords() throws {
        let favorites = try parse("""
        [{"Name":"First DB","Host":"localhost","User":"alice","Password":" p@ss:密码 ","Port":3307},
         {"Name":"Second DB","Host":"db.example","User":"bob","Password":"","Database":"reports"}]
        """)
        XCTAssertEqual(favorites.count, 2)
        XCTAssertEqual(favorites[0]["name"] as? String, "First DB")
        XCTAssertEqual(favorites[0]["port"] as? String, "3307")
        XCTAssertEqual(favorites[0]["password"] as? String, " p@ss:密码 ")
        XCTAssertEqual(favorites[1]["port"] as? String, "3306")
        XCTAssertEqual(favorites[1]["database"] as? String, "reports")
    }

    func testSingleAndWrappedObjects() throws {
        for json in [
            "{\"name\":\"DB\",\"host\":\"localhost\",\"user\":\"root\",\"port\":\"3306\"}",
            "{\"Connections\":[{\"Name\":\"DB\",\"Host\":\"localhost\",\"User\":\"root\"}]}"
        ] {
            XCTAssertEqual(try parse(json).first?["name"] as? String, "DB")
        }
    }

    func testRejectsInvalidRecordsWithoutLeakingValues() {
        for json in ["[]", "null", "[42]", "{\"Name\":\"secret\"}",
                     "{\"Name\":\"DB\",\"Host\":\"h\",\"User\":\"u\",\"Port\":true}",
                     "{\"Name\":\"DB\",\"Host\":\"h\",\"User\":\"u\",\"Password\":42}",
                     "{\"Name\":\"DB\",\"name\":\"other\",\"Host\":\"h\",\"User\":\"u\"}",
                     "{\"Password\":\"secret"] {
            XCTAssertThrowsError(try parse(json)) { error in
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
        for port in ["0", "65536", "1.5", "null", "\"abc\""] {
            XCTAssertThrowsError(try parse("{\"Name\":\"DB\",\"Host\":\"h\",\"User\":\"u\",\"Port\":\(port)}"))
        }
    }

    func testCredentialsRemovedBeforePersistenceAndBoundToFreshID() throws {
        let favorites = try parse("""
        [{"Name":"DB","Host":"h","User":"u","Password":"secret"},
         {"Name":"DB2","Host":"h2","User":"u","Password":""}]
        """)
        favorites[0]["id"] = NSNumber(value: 123)
        favorites[1]["id"] = NSNumber(value: 456)
        let credentials = SAJSONImportCredentials(items: favorites)
        XCTAssertEqual(credentials.password(for: favorites[0]), "secret")
        XCTAssertEqual(credentials.password(for: favorites[1]), "")
        XCTAssertNil(favorites[0]["password"])
        XCTAssertNil(favorites[1]["password"])
        let plist = try PropertyListSerialization.data(fromPropertyList: favorites, format: .xml, options: 0)
        XCTAssertFalse(String(decoding: plist, as: UTF8.self).contains("secret"))
    }
}

private final class SAJSONTestKeychain: NSObject, SAKeychainProviding {
    var reads = 0
    var stored: String?
    var savedName: String?
    func add(password: String?, name: String?, account: String?) { stored = password; savedName = name }
    func add(password: String?, name: String?, account: String?, label: String?) { add(password: password, name: name, account: account) }
    func password(name: String?, account: String?) -> String? { reads += 1; return stored }
    func deletePassword(name: String?, account: String?) { stored = nil }
    func passwordExists(name: String?, account: String?) -> Bool { stored != nil }
    func updateItem(name: String?, account: String?, toName newName: String?, newAccount: String?, password: String?) { stored = password; savedName = newName }
    func name(favoriteName: String?, id favoriteID: Any?) -> String? { "\(favoriteName ?? ""):\(favoriteID ?? "")" }
    func account(user: String?, host: String?, database: String?) -> String? { "\(user ?? "")@\(host ?? "")/\(database ?? "")" }
    func sshName(favoriteName: String?, id favoriteID: Any?) -> String? { nil }
    func sshAccount(user: String?, host: String?) -> String? { nil }
}

extension SAJSONFavoritesTests {
    func testPasswordUpdatesUseRetainedIdentityAndAllowEmptyPassword() throws {
        let favorites = try parse("""
        [{"Name":"Import","Host":"h","User":"u","Password":""}]
        """)
        favorites[0]["id"] = NSNumber(value: 123)
        let credentials = SAJSONImportCredentials(items: favorites)
        let existing: NSDictionary = ["id": NSNumber(value: 999), "name": "Existing", "host": "h", "user": "u"]
        let keychain = SAJSONTestKeychain()
        keychain.stored = "old"
        credentials.savePassword(for: existing, importedFavorite: favorites[0], keychain: keychain)
        XCTAssertEqual(keychain.stored, "")
        XCTAssertEqual(keychain.savedName, "Existing:999")
    }

    func testNewPasswordIsSavedAndMissingPasswordLeavesExistingValue() throws {
        let favorites = try parse("""
        [{"Name":"DB","Host":"h","User":"u","Password":"secret"},
         {"Name":"DB2","Host":"h","User":"u"}]
        """)
        favorites[0]["id"] = NSNumber(value: 1)
        favorites[1]["id"] = NSNumber(value: 2)
        let credentials = SAJSONImportCredentials(items: favorites)
        let keychain = SAJSONTestKeychain()
        credentials.savePassword(for: favorites[0], importedFavorite: favorites[0], keychain: keychain)
        XCTAssertEqual(keychain.stored, "secret")
        credentials.savePassword(for: favorites[1], importedFavorite: favorites[1], keychain: keychain)
        XCTAssertEqual(keychain.stored, "secret")
    }
}

extension SAJSONFavoritesTests {
    func testGroupingFieldsAreTransientAndKeepTheirOrder() throws {
        let favorites = try parse("""
        [{"Name":"DB","Host":"h","User":"u","level1":"fo","level2":"uat","Password":"secret"},
         {"Name":"DB2","Host":"h2","User":"u","Level1":"fo"},
         {"Name":"DB3","Host":"h3","User":"u"}]
        """)
        for (index, favorite) in favorites.enumerated() { favorite["id"] = NSNumber(value: index) }
        let credentials = SAJSONImportCredentials(items: favorites)
        XCTAssertEqual(credentials.groupPath(for: favorites[0]), ["fo", "uat"])
        XCTAssertEqual(credentials.groupPath(for: favorites[1]), ["fo"])
        XCTAssertEqual(credentials.groupPath(for: favorites[2]), [])
        XCTAssertNil(favorites[0]["_saJSONGroupPath"])
        XCTAssertNil(favorites[0]["password"])
        XCTAssertEqual(credentials.password(for: favorites[0]), "secret")
    }

    func testRejectsOrphanOrMalformedGroupingFields() {
        for fields in ["\"level2\":\"uat\"", "\"level1\":42", "\"level1\":\" \"", "\"level1\":null",
                       "\"level1\":\"fo\",\"level2\":false"] {
            XCTAssertThrowsError(try parse("{\"Name\":\"DB\",\"Host\":\"h\",\"User\":\"u\",\(fields)}"))
        }
    }
}

extension SAJSONFavoritesTests {
    func testPlaintextExportRoundTripsNamesFoldersPasswordsAndSSLOptions() throws {
        let original: NSDictionary = ["name":"订单库", "host":"db.example", "user":"reader", "id":1,
                                      "database":"app", "port":"3307", "type":0, "useSSL":1,
                                      "sslCACertFileLocation":"/tmp/ca.pem", "colorIndex":3]
        let keychain = SAJSONTestKeychain()
        keychain.stored = " 密码 @ : \\\n\" "
        let data = try SAJSONFavoritesExport.data(connections: [SAJSONExportConnection(favorite: original, groupPath: ["fo", "uat"])], keychain: keychain)
        let imported = try SAJSONFavorites.favorites(from: data)
        XCTAssertEqual(imported[0]["name"] as? String, "订单库")
        XCTAssertEqual(imported[0]["password"] as? String, keychain.stored)
        XCTAssertEqual(imported[0]["_saJSONGroupPath"] as? [String], ["fo", "uat"])
        XCTAssertEqual(imported[0]["port"] as? String, "3307")
        XCTAssertEqual(imported[0]["useSSL"] as? Int, 1)
        XCTAssertEqual(imported[0]["sslCACertFileLocation"] as? String, "/tmp/ca.pem")
        XCTAssertNil(original["password"])
        XCTAssertEqual(keychain.reads, 1)
    }

    func testExportDistinguishesMissingAndEmptyPasswords() throws {
        let favorite: NSDictionary = ["name":"DB", "host":"h", "user":"u", "id":1, "port":""]
        let connection = SAJSONExportConnection(favorite: favorite, groupPath: [])
        let keychain = SAJSONTestKeychain()
        let missing = try SAJSONFavoritesExport.data(connections: [connection], keychain: keychain)
        XCTAssertNil(try SAJSONFavorites.favorites(from: missing)[0]["password"])
        keychain.stored = ""
        let empty = try SAJSONFavoritesExport.data(connections: [connection], keychain: keychain)
        XCTAssertEqual(try SAJSONFavorites.favorites(from: empty)[0]["password"] as? String, "")
    }

    func testUnsupportedExportsDoNotReadPasswords() {
        let keychain = SAJSONTestKeychain()
        for type: Any in [NSNumber(value: 2), "2"] {
            let favorite: NSDictionary = ["name":"SSH", "host":"h", "user":"u", "type":type]
            XCTAssertThrowsError(try SAJSONFavoritesExport.data(connections: [SAJSONExportConnection(favorite: favorite, groupPath: [])], keychain: keychain))
        }
        let favorite: NSDictionary = ["name":"DB", "host":"h", "user":"u", "type":0]
        XCTAssertThrowsError(try SAJSONFavoritesExport.data(connections: [SAJSONExportConnection(favorite: favorite, groupPath: ["a", "b", "c"])], keychain: keychain))
        XCTAssertEqual(keychain.reads, 0)
    }

    func testImportedOptionsCannotOverrideIdentityOrInjectCredentials() {
        for option in ["\"password\":\"secret\"", "\"id\":999", "\"type\":2", "\"useSSL\":{}"] {
            XCTAssertThrowsError(try parse("{\"Name\":\"DB\",\"Host\":\"h\",\"User\":\"u\",\"Options\":{\(option)}}"))
        }
    }
}
