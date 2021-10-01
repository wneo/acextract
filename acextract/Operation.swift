//
//  Operation.swift
//
//  The MIT License (MIT)
//
//  Copyright (c) 2016 Bartosz Janda
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import Foundation

// MARK: - Protocols
protocol Operation {
    func read(catalog: AssetsCatalog) throws
}

struct CompoundOperation: Operation {
    let operations: [Operation]

    func read(catalog: AssetsCatalog) throws {
        for operation in operations {
            try operation.read(catalog: catalog)
        }
    }
}

// MARK: - Helpers
let escapeSeq = "\u{1b}"
let boldSeq = "[1m"
let resetSeq = "[0m"
let redColorSeq = "[31m"

// MARK: - ExtractOperation
enum ExtractOperationError: Error {
    case outputPathIsNotDirectory
    case renditionMissingData
    case cannotSaveImage
    case cannotCreatePDFDocument
    case invalidData
}
enum Model: String {
    case normal
    case dir
}

struct ExtractOperation: Operation {
    // MARK: Properties
    let outputPath: String
    let model: Model

    // MARK: Initialization
    init(path: String, mode: String? = nil) {
        outputPath = (path as NSString).expandingTildeInPath
        if let m = mode {
            model = Model(rawValue: m) ?? .normal
        } else {
            model = .normal
        }
    }

    // MARK: Methods
    func read(catalog: AssetsCatalog) throws {
        // Create output folder if needed
        try checkAndCreateFolder()
        // For every image set and every named image.
        for imageSet in catalog.imageSets {
            for namedImage in imageSet.namedImages {
                // Save image to file.
                extractNamedImage(namedImage: namedImage)
            }
        }
    }

    // MARK: Private methods
    /**
     Checks if output folder exists nad create it if needed.

     - throws: Throws if output path is pointing to file, or it si not possible to create folder.
     */
    private func checkAndCreateFolder() throws {
        // Check if directory exists at given path and it is directory.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: outputPath, isDirectory: &isDirectory) && !(isDirectory.boolValue) {
            throw ExtractOperationError.outputPathIsNotDirectory
        } else {
            try FileManager.default.createDirectory(atPath: outputPath, withIntermediateDirectories: true, attributes: nil)
        }
    }

    /**
     Extract image to file.

     - parameter namedImage: Named image to save.
     */
    private func extractNamedImage(namedImage: CUINamedImage) {
        let filePath = (outputPath as NSString).appendingPathComponent(namedImage.acImageName)
        print("Extracting: \(namedImage.acImageName)", terminator: "")
        do {
            try namedImage.acSaveAtPath(filePath: filePath, mode: model)
            print(" \(escapeSeq+boldSeq)OK\(escapeSeq+resetSeq)")
        } catch {
            print(" \(escapeSeq+boldSeq)\(escapeSeq+redColorSeq)FAILED\(escapeSeq+resetSeq) \(error)")
        }
    }
}

struct ImageDirInfo: Codable {
    enum Scale: Int, Codable, CaseIterable, Hashable {
        case one = 1
        case two = 2
        case third = 3
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(contentValue)
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let v = try container.decode(String.self)
            if let firstPart = v.components(separatedBy: .decimalDigits.inverted).first(where: { !$0.isEmpty }),
               let indexNum = Int(firstPart), let s = Scale(rawValue: indexNum) {
                self = s
            } else {
                throw ExtractOperationError.invalidData
            }
        }
        
        var tail: String {
            return "@\(rawValue)x"
        }
        var contentValue: String {
            return "\(rawValue)x"
        }
        var index: Int {
            return rawValue - 1
        }
        
        init(name: String) {
            for i in Scale.allCases {
                if name.lowercased().contains(i.tail) {
                    self = i
                    return
                }
            }
            self = .one
        }
        
        static func createElems(name: String) -> [Elem] {
            var elems: [Elem] = Scale.allCases.map({ Elem.init(scale: $0) })
            let scale = Scale(name: name)
            elems.enumerated().forEach { e in
                if e.element.scale == scale {
                    var updateElem = e.element
                    updateElem.filename = name
                    elems[e.offset] = updateElem
                }
            }
            return elems
        }
    }
    struct Elem: Codable {
        var filename: String?
        var idiom = "universal"
        var scale: Scale
    }
    struct Auth: Codable {
        var author = "xcode"
        var version = 1
    }
    
    var images: [Elem]
    var info = Auth()
    
    init(fileName: String) {
        images = Scale.createElems(name: fileName)
    }
    
    mutating func update(fileName: String) {
        let scale = Scale(name: fileName)
        images[scale.index].filename = fileName
    }
    /*
     {
       "images" : [
         {
           "idiom" : "universal",
           "scale" : "1x"
         },
         {
           "filename" : "1.2_lightmap256x256@2x.png",
           "idiom" : "universal",
           "scale" : "2x"
         },
         {
           "idiom" : "universal",
           "scale" : "3x"
         }
       ],
       "info" : {
         "author" : "xcode",
         "version" : 1
       }
     }

     */
}

private extension CUINamedImage {
    func prepareDir(orgPath: URL) throws -> URL {
        let filename = orgPath.lastPathComponent
        let scale = ImageDirInfo.Scale(name: filename)
        let ext = orgPath.pathExtension
        let pureName = filename
            .replacingOccurrences(of: ext.isEmpty ? "" : "." + ext, with: "")
            .replacingOccurrences(of: scale.tail, with: "")
            .replacingOccurrences(of: scale.tail.uppercased(), with: "")
        
        let dirPath = orgPath.deletingLastPathComponent().appendingPathComponent(pureName + ".imageset")
        
        // 检查是否存在
        var info: ImageDirInfo
        let jsonURl = dirPath.appendingPathComponent("Contents.json")
        if FileManager.default.fileExists(atPath: jsonURl.path) {
            info = try JSONDecoder().decode(ImageDirInfo.self, from: try Data(contentsOf: jsonURl))
            info.update(fileName: filename)
        } else {
            info = ImageDirInfo(fileName: filename)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let json = try encoder.encode(info)

        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true, attributes: nil)
        try json.write(to: jsonURl)
        
        return dirPath.appendingPathComponent(filename)
    }
    
}
private extension CUINamedImage {
    /**
     Extract given image as PNG or PDF file.

     - parameter filePath: Path where file should be saved.

     - throws: Thorws if there is no image data.
     */
    func acSaveAtPath(filePath: String, mode: Model) throws {
        if self._rendition().pdfDocument() != nil {
            //try self.acSavePDF(filePath: filePath)
        } else if self._rendition().unslicedImage() != nil {
            try self.acSaveImage(filePath: filePath, mode: mode)
        } else {
            throw ExtractOperationError.renditionMissingData
        }
    }

    func acSaveImage(filePath: String, mode: Model) throws {
        var filePathURL = NSURL(fileURLWithPath: filePath)
        
        // 不同模式, 生成不同目录
        switch mode {
        case .normal:
            break
        case .dir:// 生成特殊目录
            filePathURL = try prepareDir(orgPath: filePathURL as URL) as NSURL
            break
        }
        
        guard let cgImage = self._rendition().unslicedImage()?.takeUnretainedValue() else {
            print("conv1 error: \(filePathURL.lastPathComponent ?? "")")
            throw ExtractOperationError.cannotSaveImage
        }
        guard let cgDestination = CGImageDestinationCreateWithURL(filePathURL, kUTTypePNG, 1, nil) else {
            print("conv2 error: \(filePathURL.lastPathComponent ?? "")")
            throw ExtractOperationError.cannotSaveImage
        }

        CGImageDestinationAddImage(cgDestination, cgImage, nil)

        if !CGImageDestinationFinalize(cgDestination) {
            print("conv3 error: \(filePathURL.lastPathComponent ?? "")")
            throw ExtractOperationError.cannotSaveImage
        }
    }

//    func acSavePDF(filePath: String) throws {
//        // Based on:
//        // http://stackoverflow.com/questions/3780745/saving-a-pdf-document-to-disk-using-quartz
//
//        guard let cgPDFDocument = self._rendition().pdfDocument()?.takeUnretainedValue() else {
//            throw ExtractOperationError.cannotCreatePDFDocument
//        }
//        // Create the pdf context
//        let cgPage = CGPDFDocument.page(cgPDFDocument) as! CGPDFPage // swiftlint:disable:this force_cast
//        var cgPageRect = cgPage.getBoxRect(.mediaBox)
//        let mutableData = NSMutableData()
//
//        let cgDataConsumer = CGDataConsumer(data: mutableData)
//        let cgPDFContext = CGContext(consumer: cgDataConsumer!, mediaBox: &cgPageRect, nil)
//        defer {
//            cgPDFContext!.closePDF()
//        }
//
//        if cgPDFDocument.numberOfPages > 0 {
//            cgPDFContext!.beginPDFPage(nil)
//            cgPDFContext!.drawPDFPage(cgPage)
//            cgPDFContext!.endPDFPage()
//        } else {
//            throw ExtractOperationError.cannotCreatePDFDocument
//        }
//
//        if !mutableData.write(toFile: filePath, atomically: true) {
//            throw ExtractOperationError.cannotCreatePDFDocument
//        }
//    }
}
