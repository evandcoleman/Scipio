//
//  XcodeProject+Extension.swift
//
//
//  Created by Evan Coleman on 8/13/24.
//

import Foundation
import TSCBasic
import TSCUtility

extension Xcode.Project {

    var frameworkTargets: [Xcode.Target] {
        targets.filter { $0.productType == .framework }
    }

    func save(to path: AbsolutePath) throws {
        try open(path.appending(component: "project.pbxproj")) { stream in
            // Serialize the project model we created to a plist, and return
            // its string description.
#if swift(>=5.6)
            let str = try "// !$*UTF8*$!\n" + self.generatePlist().description
#else
            let str = "// !$*UTF8*$!\n" + self.generatePlist().description
#endif
            stream(str)
        }

        for target in self.frameworkTargets {
            ///// For framework targets, generate target.c99Name_Info.plist files in the
            ///// directory that Xcode project is generated
            let name = "\(target.name.spm_mangledToC99ExtendedIdentifier())_Info.plist"
            try open(path.appending(RelativePath(name))) { print in
                print(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <plist version="1.0">
                    <dict>
                    <key>CFBundleDevelopmentRegion</key>
                    <string>en</string>
                    <key>CFBundleExecutable</key>
                    <string>$(EXECUTABLE_NAME)</string>
                    <key>CFBundleIdentifier</key>
                    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
                    <key>CFBundleInfoDictionaryVersion</key>
                    <string>6.0</string>
                    <key>CFBundleName</key>
                    <string>$(PRODUCT_NAME)</string>
                    <key>CFBundlePackageType</key>
                    <string>FMWK</string>
                    <key>CFBundleShortVersionString</key>
                    <string>1.0</string>
                    <key>CFBundleSignature</key>
                    <string>????</string>
                    <key>CFBundleVersion</key>
                    <string>$(CURRENT_PROJECT_VERSION)</string>
                    <key>NSPrincipalClass</key>
                    <string></string>
                    </dict>
                    </plist>
                    """
                )
            }
        }
    }
}

private func open(_ path: AbsolutePath, body: ((String) -> Void) throws -> Void) throws {
    let stream = BufferedOutputByteStream()
    try body { line in
        stream <<< line
        stream <<< "\n"
    }
    // If the file exists with the identical contents, we don't need to rewrite it.
    //
    // This avoids unnecessarily triggering Xcode reloads of the project file.
    if let contents = try? localFileSystem.readFileContents(path), contents == stream.bytes {
        return
    }

    // Write the real file.
    try localFileSystem.writeFileContents(path, bytes: stream.bytes)
}
