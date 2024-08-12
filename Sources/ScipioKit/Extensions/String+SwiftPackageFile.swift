//
//  String+SwiftPackageFile.swift
//
//
//  Created by Evan Coleman on 10/25/23.
//

import Foundation
import RegexBuilder

extension String {

    var swiftPackageFile: SwiftPackageFileString {
        SwiftPackageFileString(contents: self)
    }
}

struct SwiftPackageFileString {

    var contents: String

    mutating func replaceProductName(_ productName: String, newName: String) {

        let regex = Regex {
            Capture {
                ".library"
                ZeroOrMore(.whitespace)
                "("
                ZeroOrMore(.whitespace)
                "name"
                ZeroOrMore(.whitespace)
                ":"
                ZeroOrMore(.whitespace)
                #"""#
            }
            Capture {
                One(productName)
            }
            Capture {
                #"""#
            }
        }

        contents = contents.replacing(regex) { match -> String in
            return [String(match.1), newName, String(match.3)]
                .joined()
        }
    }

    mutating func replaceTargetName(_ targetName: String, newName: String) {

        let regex = Regex {
            Capture {
                ".target"
                ZeroOrMore(.whitespace)
                "("
                ZeroOrMore(.whitespace)
                "name"
                ZeroOrMore(.whitespace)
                ":"
                ZeroOrMore(.whitespace)
                #"""#
            }
            Capture {
                One(targetName)
            }
            Capture {
                #"""#
            }
        }

        contents = contents.replacing(regex) { match -> String in
            return [String(match.1), newName, String(match.3)]
                .joined()
        }

        replaceDependencyTargetName(targetName, newName: newName)
        replaceProductTargetName(targetName, newName: newName)
    }

    mutating func replaceDependencyTargetName(_ targetName: String, newName: String) {

        let regex = Regex {
            Capture {
                "dependencies"
                ZeroOrMore(.whitespace)
                ":"
                ZeroOrMore(.whitespace)
                "["
                ZeroOrMore(.whitespace)
                #"""#
            }
            Capture {
                One(targetName)
            }
            Capture {
                #"""#
                ZeroOrMore(.whitespace)
            }
        }

        contents = contents.replacing(regex) { match -> String in
            return [String(match.1), newName, String(match.3)]
                .joined()
        }
    }

    mutating func replaceProductTargetName(_ targetName: String, newName: String) {

        let regex = Regex {
            Capture {
                "targets"
                ZeroOrMore(.whitespace)
                ":"
                ZeroOrMore(.whitespace)
                "["
                ZeroOrMore(.whitespace)
                #"""#
            }
            Capture {
                One(targetName)
            }
            Capture {
                #"""#
                ZeroOrMore(.whitespace)
            }
        }

        contents = contents.replacing(regex) { match -> String in
            return [String(match.1), newName, String(match.3)]
                .joined()
        }
    }
}
