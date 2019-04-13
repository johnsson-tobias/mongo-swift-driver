import bson
import Foundation

#if compiler(>=5.0)
internal typealias BSONPointer = OpaquePointer
internal typealias MutableBSONPointer = OpaquePointer
#else
internal typealias BSONPointer = UnsafePointer<bson_t>
internal typealias MutableBSONPointer = UnsafeMutablePointer<bson_t>
#endif

/// The storage backing a MongoSwift `Document`.
public class DocumentStorage {
    internal var pointer: MutableBSONPointer!

    // Normally, this would go under Document, but computed properties cannot be used before all stored properties are
    // initialized. Putting this under DocumentStorage gives a correct count and use of it inside of an init() as long
    // as we have initialized Document.storage beforehand.
    internal var count: Int {
        return Int(bson_count_keys(self.pointer))
    }

    internal init() {
        self.pointer = bson_new()
    }

    internal init(copying pointer: BSONPointer) {
        self.pointer = bson_copy(pointer)
    }

    internal init(stealing pointer: MutableBSONPointer) {
        self.pointer = pointer
    }

    /// Cleans up internal state.
    deinit {
        guard let pointer = self.pointer else {
            return
        }

        bson_destroy(pointer)
        self.pointer = nil
    }
}

/// A struct representing the BSON document type.
@dynamicMemberLookup
public struct Document {
    /// the storage backing this document
    internal var storage: DocumentStorage

    /// Returns the number of (key, value) pairs stored at the top level of this `Document`.
    public var count: Int
}

/// An extension of `Document` containing its private/internal functionality.
extension Document {
    /// direct access to the storage's pointer to a bson_t
    internal var data: MutableBSONPointer {
        return storage.pointer
    }

    /**
     * Initializes a `Document` from a pointer to a `bson_t` by making a copy of the
     * data. The caller is responsible for freeing the original `bson_t`.
     *
     * - Parameters:
     *   - pointer: a BSONPointer
     *
     * - Returns: a new `Document`
     */
    internal init(copying pointer: BSONPointer) {
        self.storage = DocumentStorage(copying: pointer)
        self.count = self.storage.count
    }

    /**
     * Initializes a `Document` from a pointer to a `bson_t`, using the `bson_t` as its
     * underlying storage. The caller must not modify or free the `bson_t` themselves.
     *
     * - Parameters:
     *   - pointer: a MutableBSONPointer
     *
     * - Returns: a new `Document`
     */
    internal init(stealing pointer: MutableBSONPointer) {
        self.storage = DocumentStorage(stealing: pointer)
        self.count = self.storage.count
    }

    /**
     * Initializes a `Document` using an array where the values are KeyValuePairs.
     *
     * - Parameters:
     *   - elements: a `[KeyValuePair]`
     *
     * - Returns: a new `Document`
     */
    internal init(_ elements: [KeyValuePair]) {
        self.storage = DocumentStorage()
        self.count = 0
        for (key, value) in elements {
            do {
                try self.setValue(for: key, to: value)
            } catch {
                fatalError("Failed to set the value for \(key) to \(String(describing: value)): \(error)")
            }
        }
    }

    /**
     * Initializes a `Document` using an array where the values are optional
     * `BSONValue`s. Values are stored under a string of their index in the
     * array.
     *
     * - Parameters:
     *   - elements: a `[BSONValue]`
     *
     * - Returns: a new `Document`
     */
    internal init(_ elements: [BSONValue]) {
        self.storage = DocumentStorage()
        self.count = 0
        for (i, elt) in elements.enumerated() {
            do {
                try self.setValue(for: String(i), to: elt, checkForKey: false)
            } catch {
                fatalError("Failed to set the value for index \(i) to \(String(describing: elt)): \(error)")
            }
        }
    }

    /**
     * Sets key to newValue. if checkForKey=false, the key/value pair will be appended without checking for the key's
     * presence first.
     *
     * - Throws:
     *   - `RuntimeError.internalError` if the new value is an `Int` and cannot be written to BSON.
     *   - `UserError.logicError` if the new value is a `Decimal128` or `ObjectId` and is improperly formatted.
     *   - `UserError.logicError` if the new value is an `Array` and it contains a non-`BSONValue` element.
     *   - `RuntimeError.internalError` if the `DocumentStorage` would exceed the maximum size by encoding this
     *     key-value pair.
     */
    internal mutating func setValue(for key: String, to newValue: BSONValue, checkForKey: Bool = true) throws {
        // if the key already exists in the `Document`, we need to replace it
        if checkForKey, let existingType = DocumentIterator(forDocument: self, advancedTo: key)?.currentType {
            let newBSONType = newValue.bsonType
            let sameTypes = newBSONType == existingType

            // if the new type is the same and it's a type with no custom data, no-op
            if sameTypes && [.null, .undefined, .minKey, .maxKey].contains(newBSONType) {
                return
            }

            // if the new type is the same and it's a fixed length type, we can overwrite
            if let ov = newValue as? Overwritable, ov.bsonType == existingType {
                self.copyStorageIfRequired()
                // swiftlint:disable:next force_unwrapping - key is guaranteed present so initialization will succeed.
                try DocumentIterator(forDocument: self, advancedTo: key)!.overwriteCurrentValue(with: ov)

            // otherwise, we just create a new document and replace this key
            } else {
                // TODO SWIFT-224: use va_list variant of bson_copy_to_excluding to improve performance
                var newSelf = Document()
                var seen = false
                try self.forEach { pair in
                    if !seen && pair.key == key {
                        seen = true
                        try newSelf.setValue(for: pair.key, to: newValue)
                    } else {
                        try newSelf.setValue(for: pair.key, to: pair.value)
                    }
                }
                self = newSelf
            }

        // otherwise, it's a new key
        } else {
            self.copyStorageIfRequired()
            try newValue.encode(to: self.storage, forKey: key)
            self.count += 1
        }
    }

    /// Retrieves the value associated with `for` as a `BSONValue?`, which can be nil if the key does not exist in the
    /// `Document`.
    ///
    /// - Throws: `RuntimeError.internalError` if the BSON buffer is too small (< 5 bytes).
    internal func getValue(for key: String) throws -> BSONValue? {
        guard let iter = DocumentIterator(forDocument: self) else {
            throw RuntimeError.internalError(message: "BSON buffer is unexpectedly too small (< 5 bytes)")
        }

        guard iter.move(to: key) else {
            return nil
        }

        return try iter.safeCurrentValue()
    }

    /**
     * Allows retrieving and strongly typing a value at the same time. This means you can avoid
     * having to cast and unwrap values from the `Document` when you know what type they will be.
     * For example:
     * ```
     *  let d: Document = ["x": 1]
     *  let x: Int = try d.get("x")
     *  ```
     *
     *  - Parameters:
     *      - key: The key under which the value you are looking up is stored
     *      - `T`: Any type conforming to the `BSONValue` protocol
     *  - Returns: The value stored under key, as type `T`
     *  - Throws:
     *    - `RuntimeError.internalError` if the value cannot be cast to type `T` or is not in the `Document`, or an
     *      unexpected error occurs while decoding the `BSONValue`.
     *
     */
    internal func get<T: BSONValue>(_ key: String) throws -> T {
        guard let value = try self.getValue(for: key) as? T else {
            throw RuntimeError.internalError(message: "Could not cast value for key \(key) to type \(T.self)")
        }
        return value
    }

    /// Appends the key/value pairs from the provided `doc` to this `Document`.
    /// Note: This function does not check for or clean away duplicate keys.
    internal mutating func merge(_ doc: Document) throws {
        self.copyStorageIfRequired()
        guard bson_concat(self.data, doc.data) else {
            throw RuntimeError.internalError(message: "Failed to merge \(doc) with \(self). This is likely due to " +
                    "the merged document being too large.")
        }
        self.count += doc.count
    }

    /**
     * Checks if the document is uniquely referenced. If not, makes a copy of the underlying `bson_t`
     * and lets the copy/copies keep the original. This allows us to provide value semantics for `Document`s.
     * This happens if someone copies a document and modifies it.
     *
     * For example:
     *      let doc1: Document = ["a": 1]
     *      var doc2 = doc1
     *      doc2.setValue(forKey: "b", to: 2)
     *
     * Therefore, this function should be called just before we are about to modify a document - either by
     * setting a value or merging in another doc.
     */
    private mutating func copyStorageIfRequired() {
        if !isKnownUniquelyReferenced(&self.storage) {
            self.storage = DocumentStorage(copying: self.data)
        }
    }

    /// If the document already has an _id, returns it as-is. Otherwise, returns a new document
    /// containing all the keys from this document, with an _id prepended.
    internal func withID() throws -> Document {
        if self.hasKey("_id") {
            return self
        }

        var idDoc: Document = ["_id": ObjectId()]
        try idDoc.merge(self)
        return idDoc
    }
}

/// An extension of `Document` containing its public API.
extension Document {
    /// Returns a `[String]` containing the keys in this `Document`.
    public var keys: [String] {
        return self.makeIterator().keys
    }

    /// Returns a `[BSONValue]` containing the values stored in this `Document`.
    public var values: [BSONValue] {
        return self.makeIterator().values
    }

    /// Returns the relaxed extended JSON representation of this `Document`.
    /// On error, an empty string will be returned.
    public var extendedJSON: String {
        guard let json = bson_as_relaxed_extended_json(self.data, nil) else {
            return ""
        }

        defer {
            bson_free(json)
        }

        return String(cString: json)
    }

    /// Returns the canonical extended JSON representation of this `Document`.
    /// On error, an empty string will be returned.
    public var canonicalExtendedJSON: String {
        guard let json = bson_as_canonical_extended_json(self.data, nil) else {
            return ""
        }

        defer {
            bson_free(json)
        }

        return String(cString: json)
    }

    /// Returns a copy of the raw BSON data for this `Document`, represented as `Data`.
    public var rawBSON: Data {
        // swiftlint:disable:next force_unwrapping - documented as always returning a value.
        let data = bson_get_data(self.data)!

        /// BSON encodes the length in the first four bytes, so we can read it in from the
        /// raw data without needing to access the `len` field of the `bson_t`.
        let length = data.withMemoryRebound(to: Int32.self, capacity: 4) { $0.pointee }

        return Data(bytes: data, count: Int(length))
    }

    /// Initializes a new, empty `Document`.
    public init() {
        self.storage = DocumentStorage()
        self.count = 0
    }

    /**
     * Constructs a new `Document` from the provided JSON text.
     *
     * - Parameters:
     *   - fromJSON: a JSON document as `Data` to parse into a `Document`
     *
     * - Returns: the parsed `Document`
     *
     * - Throws:
     *   - A `UserError.invalidArgumentError` if the data passed in is invalid JSON.
     */
    public init(fromJSON: Data) throws {
        self.storage = DocumentStorage(stealing: try fromJSON.withUnsafeBytes { (bytes: UnsafePointer<UInt8>) in
            var error = bson_error_t()
            guard let bson = bson_new_from_json(bytes, fromJSON.count, &error) else {
                if error.domain == BSON_ERROR_JSON {
                    throw UserError.invalidArgumentError(message: "Invalid JSON: \(toErrorString(error))")
                }
                throw RuntimeError.internalError(message: toErrorString(error))
            }

            return bson
        })
        self.count = self.storage.count
    }

    /// Convenience initializer for constructing a `Document` from a `String`.
    /// - Throws:
    ///   - A `UserError.invalidArgumentError` if the string passed in is invalid JSON.
    public init(fromJSON json: String) throws {
        // `String`s are Unicode under the hood so force unwrap always succeeds.
        // see https://www.objc.io/blog/2018/02/13/string-to-data-and-back/
        try self.init(fromJSON: json.data(using: .utf8)!) // swiftlint:disable:this force_unwrapping
    }

    /// Constructs a `Document` from raw BSON `Data`.
    public init(fromBSON: Data) {
        self.storage = DocumentStorage(stealing: fromBSON.withUnsafeBytes { (bytes: UnsafePointer<UInt8>) in
            bson_new_from_data(bytes, fromBSON.count)
        })
        self.count = self.storage.count
    }

    /// Returns a `Boolean` indicating whether this `Document` contains the provided key.
    public func hasKey(_ key: String) -> Bool {
        return bson_has_field(self.data, key)
    }

    /**
     * Allows setting values and retrieving values using subscript syntax.
     * For example:
     *  ```
     *  let d = Document()
     *  d["a"] = 1
     *  print(d["a"]) // prints 1
     *  ```
     * A nil return suggests that the subscripted key does not exist in the `Document`. A true BSON null is returned as
     * a `BSONNull`.
     */
    public subscript(key: String) -> BSONValue? {
        // TODO: This `get` method _should_ guarantee constant-time O(1) access, and it is possible to make it do so.
        // This criticism also applies to indexed-based subscripting via `Int`.
        // See SWIFT-250.
        get { return DocumentIterator(forDocument: self, advancedTo: key)?.currentValue }
        set(newValue) {
            do {
                if let newValue = newValue {
                    try self.setValue(for: key, to: newValue)
                } else {
                    // TODO SWIFT-224: use va_list variant of bson_copy_to_excluding to improve performance
                    self = self.filter { $0.key != key }
                }
            } catch {
                fatalError("Failed to set the value for key \(key) to \(newValue ?? "nil"): \(error)")
            }
        }
    }

    /**
     * An implementation identical to subscript(key: String), but offers the ability to choose a default value if the
     * key is missing.
     * For example:
     *  ```
     *  let d: Document = ["hello": "world"]
     *  print(d["hello", default: "foo"]) // prints "world"
     *  print(d["a", default: "foo"]) // prints "foo"
     *  ```
     */
    public subscript(key: String, default defaultValue: @autoclosure () -> BSONValue) -> BSONValue {
        return self[key] ?? defaultValue()
    }

    /**
     * Allows setting values and retrieving values using dot-notation syntax.
     * For example:
     *  ```
     *  let d = Document()
     *  d.a = 1
     *  print(d.a) // prints 1
     *  ```
     * A nil return suggests that the key does not exist in the `Document`. A true BSON null is returned as
     * a `BSONNull`.
     *
     * Only available in Swift 4.2+.
     */
    @available(swift 4.2)
    public subscript(dynamicMember member: String) -> BSONValue? {
        get {
            return self[member]
        }
        set(newValue) {
            self[member] = newValue
        }
    }
}

/// An extension of `Document` to make it a `BSONValue`.
extension Document: BSONValue {
    public var bsonType: BSONType { return .document }

    public func encode(to storage: DocumentStorage, forKey key: String) throws {
        guard bson_append_document(storage.pointer, key, Int32(key.utf8.count), self.data) else {
            throw bsonTooLargeError(value: self, forKey: key)
        }
    }

    public static func from(iterator iter: DocumentIterator) throws -> Document {
        guard iter.currentType == .document else {
            throw wrongIterTypeError(iter, expected: Document.self)
        }

        return try iter.withBSONIterPointer { iterPtr in
            var length: UInt32 = 0
            let document = UnsafeMutablePointer<UnsafePointer<UInt8>?>.allocate(capacity: 1)
            defer {
                document.deinitialize(count: 1)
                document.deallocate()
            }

            bson_iter_document(iterPtr, &length, document)

            guard let docData = bson_new_from_data(document.pointee, Int(length)) else {
                throw RuntimeError.internalError(message: "Failed to create a Document from iterator")
            }

            return self.init(stealing: docData)
        }
    }
}

/// An extension of `Document` to make it `Equatable`.
extension Document: Equatable {
    public static func == (lhs: Document, rhs: Document) -> Bool {
        return bson_compare(lhs.data, rhs.data) == 0
    }
}

/// An extension of `Document` to make it convertible to a string.
extension Document: CustomStringConvertible {
    /// Returns the relaxed extended JSON representation of this `Document`.
    /// On error, an empty string will be returned.
    public var description: String {
        return self.extendedJSON
    }
}

/// An extension of `Document` to add the capability to be initialized with a dictionary literal.
extension Document: ExpressibleByDictionaryLiteral {
    /**
     * Initializes a `Document` using a dictionary literal where the
     * keys are `String`s and the values are `BSONValue`s. For example:
     * `d: Document = ["a" : 1 ]`
     *
     * - Parameters:
     *   - dictionaryLiteral: a [String: BSONValue]
     *
     * - Returns: a new `Document`
     */
    public init(dictionaryLiteral keyValuePairs: (String, BSONValue)...) {
        // make sure all keys are unique
        guard Set(keyValuePairs.map { $0.0 }).count == keyValuePairs.count else {
            fatalError("Dictionary literal \(keyValuePairs) contains duplicate keys")
        }

        self.storage = DocumentStorage()
        // This is technically not consistent, but the only way this inconsistency can cause an issue is if we fail to
        // setValue(), in which case we crash anyways.
        self.count = 0
        for (key, value) in keyValuePairs {
            do {
                try self.setValue(for: key, to: value, checkForKey: false)
            } catch {
                fatalError("Error setting key \(key) to value \(String(describing: value)): \(error)")
            }
        }
    }
}

/// An extension of `Document` to add the capability to be initialized with an array literal.
extension Document: ExpressibleByArrayLiteral {
    /**
     * Initializes a `Document` using an array literal where the values
     * are `BSONValue`s. Values are stored under a string of their
     * index in the array. For example:
     * `d: Document = ["a", "b"]` will become `["0": "a", "1": "b"]`
     *
     * - Parameters:
     *   - arrayLiteral: a `[BSONValue]`
     *
     * - Returns: a new `Document`
     */
    public init(arrayLiteral elements: BSONValue...) {
        self.init(elements)
    }
}
