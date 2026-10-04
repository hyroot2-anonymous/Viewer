import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Small DOM built with `XMLParser`. Element names keep only the local part
/// ("hp:p" → "p") because HWPX writers do not agree on namespace prefixes.
final class XMLNode {
    enum Child {
        case element(XMLNode)
        case text(String)
    }

    let name: String
    let attributes: [String: String]
    var children: [Child] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var elements: [XMLNode] {
        children.compactMap { if case .element(let e) = $0 { return e } else { return nil } }
    }

    func first(_ name: String) -> XMLNode? { elements.first { $0.name == name } }

    func all(_ name: String) -> [XMLNode] { elements.filter { $0.name == name } }

    /// Depth-first search for the first descendant with the given name.
    func descendant(_ name: String) -> XMLNode? {
        for e in elements {
            if e.name == name { return e }
            if let d = e.descendant(name) { return d }
        }
        return nil
    }

    func descendants(_ name: String) -> [XMLNode] {
        var out: [XMLNode] = []
        for e in elements {
            if e.name == name { out.append(e) }
            out.append(contentsOf: e.descendants(name))
        }
        return out
    }

    var text: String {
        children.map {
            switch $0 {
            case .text(let s): return s
            case .element(let e): return e.text
            }
        }.joined()
    }

    subscript(_ attribute: String) -> String? { attributes[attribute] }

    func int(_ attribute: String) -> Int? { attributes[attribute].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    func double(_ attribute: String) -> Double? {
        attributes[attribute].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    func bool(_ attribute: String) -> Bool {
        guard let v = attributes[attribute]?.lowercased() else { return false }
        return v == "1" || v == "true"
    }

    static func parse(_ bytes: [UInt8]) throws -> XMLNode {
        let builder = Builder()
        let parser = XMLParser(data: Data(bytes))
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        if !parser.parse() || builder.root == nil {
            let message = parser.parserError?.localizedDescription ?? "XML 오류"
            throw HWPError.invalidFormat(message)
        }
        return builder.root!
    }

    static func localName(_ qualified: String) -> String {
        if let i = qualified.lastIndex(of: ":") { return String(qualified[qualified.index(after: i)...]) }
        return qualified
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            var attrs: [String: String] = [:]
            for (k, v) in attributeDict { attrs[XMLNode.localName(k)] = v }
            let node = XMLNode(name: XMLNode.localName(elementName), attributes: attrs)
            if let parent = stack.last {
                parent.children.append(.element(node))
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let top = stack.last else { return }
            if case .text(let prev)? = top.children.last {
                top.children[top.children.count - 1] = .text(prev + string)
            } else {
                top.children.append(.text(string))
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
        }
    }
}
