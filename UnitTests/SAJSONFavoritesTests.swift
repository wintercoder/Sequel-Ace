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
    var stored: String?
    var savedName: String?
    func add(password: String?, name: String?, account: String?) { stored = password; savedName = name }
    func add(password: String?, name: String?, account: String?, label: String?) { add(password: password, name: name, account: account) }
    func password(name: String?, account: String?) -> String? { stored }
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
