//
//  PropertyObserver.swift
//  Layout
//
//  Created by Nick Lockwood on 30/03/2017.
//  Copyright © 2017 Nick Lockwood. All rights reserved.
//

import Foundation

public class RuntimeType: NSObject {
    public enum Kind {
        case any(Any.Type)
        case `protocol`(Protocol)
        case `enum`([String: Any])
    }

    public let type: Kind

    @nonobjc public init(_ type: Any.Type) {
        self.type = .any(type)
    }

    @nonobjc public init(_ type: Protocol) {
        self.type = .protocol(type)
    }

    @nonobjc public init(_ type: [String: Any]) {
        self.type = .enum(type)
    }

    override public var description: String {
        switch type {
        case let .any(type):
            return "\(type)"
        case let .protocol(type):
            return "\(type)"
        case let .enum(values):
            return "\(values.first?.value ?? "")"
        }
    }

    public func cast(_ value: Any) -> Any? {
        switch type {
        case let .any(subtype):
            switch subtype {
            case _ where "\(subtype)" == "\(CGColor.self)":
                // Workaround for odd behavior in type matching
                return (value as? UIColor).map({ $0.cgColor }) ?? value // No validation possible
            case is NSNumber.Type:
                return value as? NSNumber
            case is CGFloat.Type:
                return value as? CGFloat ?? (value as? NSNumber).map { CGFloat($0) }
            case is Double.Type:
                return value as? Double ?? (value as? NSNumber).map { Double($0) }
            case is Float.Type:
                return value as? Float ?? (value as? NSNumber).map { Float($0) }
            case is Int.Type:
                return value as? Int ?? (value as? NSNumber).map { Int($0) }
            case is Bool.Type:
                return value as? Bool ?? (value as? NSNumber).map { Double($0) != 0 }
            case is String.Type,
                 is NSString.Type:
                return value as? String ?? "\(value)"
            case is NSAttributedString.Type:
                return value as? NSAttributedString ?? NSAttributedString(string: "\(value)")
            case let subtype as AnyClass:
                return (value as AnyObject).isKind(of: subtype) ? value : nil
            case _ where subtype == Any.self:
                return value
            default:
                return subtype == type(of: value) || "\(subtype)" == "\(type(of: value))" ? value: nil
            }
        case let .enum(enumValues):
            if let key = value as? String, let value = enumValues[key] {
                return value
            }
            guard let firstValue = enumValues.first?.value else {
                return nil
            }
            let type = type(of: firstValue)
            if type != type(of: value) {
                return nil
            }
            if let value = value as? AnyHashable, let values = Array(enumValues.values) as? [AnyHashable] {
                return values.contains(value) ? value : nil
            }
            return value
        case let .protocol(type):
            return (value as AnyObject).conforms(to: type) ? value : nil
        }
    }

    public func matches(_ type: Any.Type) -> Bool {
        switch self.type {
        case let .any(_type):
            if let lhs = type as? AnyClass, let rhs = _type as? AnyClass {
                return rhs.isSubclass(of: lhs)
            }
            return type == _type || "\(type)" == "\(_type)"
        default:
            return false
        }
    }

    public func matches(_ value: Any) -> Bool {
        return cast(value) != nil
    }
}

extension NSObject {
    private static var propertiesKey = 0

    private class func localPropertyTypes() -> [String: RuntimeType] {
        // Check for memoized props
        if let memoized = objc_getAssociatedObject(self, &propertiesKey) as? [String: RuntimeType] {
            return memoized
        }
        // Gather properties
        var allProperties = [String: RuntimeType]()
        var numberOfProperties: CUnsignedInt = 0
        let properties = class_copyPropertyList(self, &numberOfProperties)
        for i in 0 ..< Int(numberOfProperties) {
            let cprop = properties?[i].unsafelyUnwrapped
            if let cname = property_getName(cprop), let cattribs = property_getAttributes(cprop) {
                var name = String(cString: cname)
                if name.hasPrefix("_") {
                    // Don't want to mess with private stuff
                    continue
                }
                // Get (non-readonly) attributes
                let attribs = String(cString: cattribs).components(separatedBy: ",")
                if attribs.contains("R") {
                    // TODO: check for KVC compliance
                    continue
                }
                let type: RuntimeType
                let typeAttrib = attribs[0]
                switch typeAttrib.characters.dropFirst().first! {
                case "c" where ObjCBool.self == CChar.self, "B":
                    type = RuntimeType(Bool.self)
                    for attrib in attribs where attrib.hasPrefix("Gis") {
                        name = attrib.substring(from: "G".endIndex)
                        break
                    }
                case "c", "i", "s", "l", "q":
                    type = RuntimeType(Int.self)
                case "C", "I", "S", "L", "Q":
                    type = RuntimeType(UInt.self)
                case "f":
                    type = RuntimeType(Float.self)
                case "d":
                    type = RuntimeType(Double.self)
                case "*":
                    type = RuntimeType(UnsafePointer<Int8>.self)
                case "@":
                    if typeAttrib.hasPrefix("T@\"") {
                        let range = "T@\"".endIndex ..< typeAttrib.index(before: typeAttrib.endIndex)
                        let className = typeAttrib.substring(with: range)
                        if let cls = NSClassFromString(className) {
                            type = RuntimeType(cls)
                            break
                        }
                        if className.hasPrefix("<") {
                            let range = "<".endIndex ..< className.index(before: className.endIndex)
                            let protocolName = className.substring(with: range)
                            if let proto = NSProtocolFromString(protocolName) {
                                type = RuntimeType(proto)
                                break
                            }
                        }
                    }
                    type = RuntimeType(AnyObject.self)
                case "#":
                    type = RuntimeType(AnyClass.self)
                case ":":
                    type = RuntimeType(Selector.self)
                default:
                    // Unsupported type
                    continue
                }
                // Store
                if allProperties[name] == nil {
                    allProperties[name] = type
                }
            }
        }
        // Memoize properties
        objc_setAssociatedObject(self, &propertiesKey, allProperties, .OBJC_ASSOCIATION_RETAIN)
        return allProperties
    }

    class func allPropertyTypes(excluding baseClass: NSObject.Type = NSObject.self) -> [String: RuntimeType] {
        assert(isSubclass(of: baseClass))
        var allProperties = [String: RuntimeType]()
        var cls: NSObject.Type = self
        while cls !== baseClass {
            for (name, type) in cls.localPropertyTypes() where allProperties[name] == nil {
                allProperties[name] = type
            }
            cls = cls.superclass() as? NSObject.Type ?? baseClass
        }
        return allProperties
    }

    // Safe version of setValue(forKeyPath:)
    func _setValue(_ value: Any, forKeyPath name: String) throws {
        var target = self as NSObject
        let parts = name.components(separatedBy: ".")
        for part in parts.dropLast() {
            guard target.responds(to: Selector(part)) else {
                throw SymbolError("Unknown property `\(part)` of `\(type(of: target))`", for: name)
            }
            guard let nextTarget = target.value(forKey: part) as? NSObject else {
                throw SymbolError("Encountered nil value for `\(part)` of `\(type(of: target))`", for: name)
            }
            target = nextTarget
        }
        // TODO: optimize this
        var key = parts.last!
        let characters = key.characters
        let setter = "set\(String(characters.first!).uppercased())\(String(characters.dropFirst())):"
        guard target.responds(to: Selector(setter)) else {
            if key.hasPrefix("is") {
                let characters = characters.dropFirst(2)
                let setter = "set\(String(characters)):"
                if target.responds(to: Selector(setter)) {
                    target.setValue(value, forKey: "\(String(characters.first!).lowercased())\(String(characters.dropFirst()))")
                    return
                }
            }
            throw SymbolError("No valid setter found for property `\(key)` of `\(type(of: target))`", for: name)
        }
        target.setValue(value, forKey: key)
    }

    /// Safe version of value(forKeyPath:)
    func _value(forKeyPath name: String) -> Any? {
        var value = self as NSObject
        for part in name.components(separatedBy: ".") {
            guard value.responds(to: Selector(part)) == true,
                let nextValue = value.value(forKey: part) as? NSObject else {
                    return nil
            }
            value = nextValue
        }
        return value
    }
}
