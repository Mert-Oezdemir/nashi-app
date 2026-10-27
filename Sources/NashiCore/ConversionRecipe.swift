import Foundation

/// A bounded, one-output-per-step pipeline. Source files are never used as
/// destinations. All stages run in a private workspace, and only complete
/// final outputs are published via ExportTransaction.
public enum NashiRecipe {
    private static let oneFileTools: Set<ToolKind> = [
        .compress, .removeMetadata, .editImage, .annotateImage, .frameImage,
        .cropImage, .normalizeAudio, .muteVideo, .trimVideo, .cropVideo,
        .changeVideoSpeed, .trimAudio, .audioChannels, .redactImage,
        .redactVideo, .redactAudio
    ]

    public static func run(definition: Data, inputs: [URL],
                           destination: URL? = nil,
                           token: CancellationToken = .init()) throws -> [URL] {
        guard definition.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: definition) as? [String: Any],
              object.keys.allSatisfy({ $0 == "steps" }),
              let steps = object["steps"] as? [[String: Any]],
              (1...10).contains(steps.count) else {
            throw NashiError.invalidInput("A recipe needs 1–10 valid steps.")
        }
        guard (1...100).contains(inputs.count) else {
            throw NashiError.invalidInput("Choose 1–100 input files.")
        }
        for input in inputs {
            guard input.isFileURL,
                  (try? input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw NashiError.invalidInput("Input must be an existing regular file: \(input.lastPathComponent)")
            }
        }
        let operations = try steps.map { step -> (Operation, OperationOptions) in
            guard step.keys.allSatisfy({ ["convert", "tool", "options"].contains($0) }),
                  (step["convert"] == nil) != (step["tool"] == nil) else {
                throw NashiError.invalidInput("Each step needs exactly one convert or tool action.")
            }
            let action: Operation
            if let raw = step["convert"] as? String {
                guard !raw.isEmpty, raw.count <= 12,
                      raw.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
                    throw NashiError.invalidInput("Invalid conversion format.")
                }
                action = .convert(raw.lowercased())
            } else if let raw = step["tool"] as? String, let kind = ToolKind(rawValue: raw),
                      oneFileTools.contains(kind) {
                action = .tool(kind)
            } else {
                throw NashiError.invalidInput("This recipe tool may produce multiple files or is not supported.")
            }
            return (action, try operationOptions(step["options"]))
        }

        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.appendingPathComponent("Nashi-Recipe-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: scratch) }
        let transaction = ExportTransaction()
        defer { transaction.cleanUp() }

        for (inputIndex, input) in inputs.enumerated() {
            try token.check()
            var current = input
            for (stepIndex, step) in operations.enumerated() {
                try token.check()
                switch step.0 {
                case .convert(let format):
                    guard FeatureCatalog.formats(for: [current]).contains(format) else {
                        throw NashiError.unsupported("Step \(stepIndex+1) cannot convert \(current.pathExtension) to \(format).")
                    }
                case .tool(let kind):
                    guard FeatureCatalog.tools(for: [current]).contains(kind) else {
                        throw NashiError.unsupported("Step \(stepIndex+1) cannot apply \(kind.rawValue) to \(current.pathExtension).")
                    }
                }
                let stage = scratch.appendingPathComponent("\(inputIndex)-\(stepIndex)", isDirectory: true)
                try manager.createDirectory(at: stage, withIntermediateDirectories: false)
                var options = step.1
                options.outputDirectory = stage
                options.revealInFinder = false
                let outputs = try ConversionEngine.run(
                    ConversionRequest(inputs: [current], operation: step.0, options: options),
                    token: token
                )
                guard outputs.count == 1,
                      outputs[0].standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(stage.path + "/") else {
                    throw NashiError.failed("A recipe step produced an unsupported number or location of outputs.")
                }
                current = outputs[0]
            }
            try token.check()
            let area = try transaction.makeArea(destination: destination ?? input.deletingLastPathComponent())
            let staged = area.directory.appendingPathComponent(current.lastPathComponent)
            try manager.copyItem(at: current, to: staged)
            try transaction.record([staged], in: area)
        }
        try token.check()
        return try transaction.publish(token: token)
    }

    private static func operationOptions(_ raw: Any?) throws -> OperationOptions {
        guard let raw else { return OperationOptions() }
        guard let dictionary = raw as? [String: Any], dictionary["outputDirectory"] == nil,
              dictionary["revealInFinder"] == nil else {
            throw NashiError.invalidInput("Recipe steps cannot choose output paths or reveal files.")
        }
        let encoder = JSONEncoder()
        var defaults = try JSONSerialization.jsonObject(with: encoder.encode(OperationOptions())) as! [String: Any]
        let optionalDefaults: [String: Data] = [
            "imageMetadata": try encoder.encode(ImageMetadataOptions()),
            "imageFrame": try encoder.encode(ImageFrameOptions()),
            "imageRedaction": try encoder.encode(ImageRedactionOptions()),
            "collage": try encoder.encode(CollageOptions())
        ]
        for (key, value) in optionalDefaults where dictionary[key] is [String: Any] {
            defaults[key] = try JSONSerialization.jsonObject(with: value)
        }
        let merged = merge(defaults, dictionary)
        guard JSONSerialization.isValidJSONObject(merged) else {
            throw NashiError.invalidInput("Invalid recipe options.")
        }
        return try JSONDecoder().decode(OperationOptions.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    private static func merge(_ base: [String: Any], _ supplied: [String: Any]) -> [String: Any] {
        base.merging(supplied) { old, new in
            if let old = old as? [String: Any], let new = new as? [String: Any] {
                return merge(old, new)
            }
            return new
        }
    }
}
