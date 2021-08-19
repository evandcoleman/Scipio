/*
 BSD 2-Clause License

 Copyright (c) 25/11/2011, Mathieu Hausherr Octo Technology and 06/06/2020, Light-Untar All rights reserved.

 Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

 Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

 Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Foundation
import PathKit

enum UntarError: Error, LocalizedError {
    case notFound(file: String)
    case corruptFile(type: UnicodeScalar)

    public var errorDescription: String? {
        switch self {
        case let .notFound(file: file): return "Source file \(file) not found"
        case let .corruptFile(type: type): return "Invalid block type \(type) found"
        }
    }
}

private let tarBlockSize: UInt64 = 512
private let tarTypePosition: UInt64 = 156
private let tarNamePosition: UInt64 = 0
private let tarNameSize: UInt64 = 100
private let tarSizePosition: UInt64 = 124
private let tarSizeSize: UInt64 = 12
private let tarMaxBlockLoadInMemory: UInt64 = 100

public extension Path {
    func untar(progress: ((Double) -> Void)? = nil) throws -> Path {
        let data: Data = try read()
        let path = parent() + lastComponentWithoutExtension

        try createFilesAndDirectories(
            path: path,
            tarObject: data,
            size: UInt64(data.count),
            progress: progress
        )

        return path
    }

    private func createFilesAndDirectories(path: Path, tarObject: Data, size: UInt64, progress: ((Double) -> Void)?) throws {

        var location: UInt64 = 0
        while location < size {
            var blockCount: UInt64 = 1
            progress?(Double(location) / Double(size))

            let type = self.type(object: tarObject, offset: location)
            switch type {
            case "0": // File
                let name = self.name(object: tarObject, offset: location)
                let filePath = path + name
                let size = self.size(object: tarObject, offset: location)
                if size == 0 {
                    try filePath.write("")
                } else {
                    blockCount += (size - 1) / tarBlockSize + 1 // size / tarBlockSize rounded up
                    writeFileData(object: tarObject, location: location + tarBlockSize, length: size, path: filePath.string)
                }
            case "5": // Directory
                let name = self.name(object: tarObject, offset: location)
                let directoryPath = (path + name)
                    .normalize()
                try directoryPath.mkpath()
            case "\0": break // Null block
            case "x": blockCount += 1 // Extra header block
            case "1": fallthrough
            case "2": fallthrough
            case "3": fallthrough
            case "4": fallthrough
            case "6": fallthrough
            case "7": fallthrough
            case "L": fallthrough
            case "g": // Not a file nor directory
                let size = self.size(object: tarObject, offset: location)
                blockCount += UInt64(ceil(Double(size) / Double(tarBlockSize)))
            default: throw UntarError.corruptFile(type: type) // Not a tar type
            }
            location += blockCount * tarBlockSize
        }
    }

    private func type(object: Any, offset: UInt64) -> UnicodeScalar {
        let typeData = data(object: object, location: offset + tarTypePosition, length: 1)!
        return UnicodeScalar([UInt8](typeData)[0])
    }

    private func name(object: Any, offset: UInt64) -> String {
        let nameData = data(object: object, location: offset + tarNamePosition, length: tarNameSize)!
        return String(data: nameData, encoding: .ascii)!
            .replacingOccurrences(of: "\0", with: "")
    }

    private func size(object: Any, offset: UInt64) -> UInt64 {
        let sizeData = data(object: object, location: offset + tarSizePosition, length: tarSizeSize)!
        let sizeString = String(data: sizeData, encoding: .ascii)!
        return strtoull(sizeString, nil, 8) // Size is an octal number, convert to decimal
    }

    private func writeFileData(object: Any, location _loc: UInt64, length _len: UInt64,
                               path: String) {
        if let data = object as? Data {
            FileManager.default.createFile(atPath: path, contents: data.subdata(in: Int(_loc) ..< Int(_loc + _len)),
                       attributes: nil)
        } else if let fileHandle = object as? FileHandle {
            if NSData().write(toFile: path, atomically: false) {
                let destinationFile = FileHandle(forWritingAtPath: path)!
                fileHandle.seek(toFileOffset: _loc)

                let maxSize = tarMaxBlockLoadInMemory * tarBlockSize
                var length = _len, location = _loc
                while length > maxSize {
                    destinationFile.write(fileHandle.readData(ofLength: Int(maxSize)))
                    location += maxSize
                    length -= maxSize
                }
                destinationFile.write(fileHandle.readData(ofLength: Int(length)))
                destinationFile.closeFile()
            }
        }
    }

    private func data(object: Any, location: UInt64, length: UInt64) -> Data? {
        if let data = object as? Data {
            return data.subdata(in: Int(location) ..< Int(location + length))
        } else if let fileHandle = object as? FileHandle {
            fileHandle.seek(toFileOffset: location)
            return fileHandle.readData(ofLength: Int(length))
        }
        return nil
    }
}
