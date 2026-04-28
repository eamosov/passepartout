// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Partout

extension Registry {
    public nonisolated func importedProfile(from input: ABI.ProfileImporterInput, passphrase: String?) throws -> Profile {
        let name: String
        let contents: String
        switch input {
        case .contents(let filename, let data):
            name = filename
            contents = data
        case .file(let url):
            var encoding: String.Encoding = .utf8
            // XXX: This may be very inefficient
            contents = try String(contentsOf: url, usedEncoding: &encoding)
            name = url.lastPathComponent
        }

        // Try to decode a full Partout profile first. Avoid feeding raw module
        // formats (notably .ovpn with PEM/base64 blocks) into legacy profile
        // decoding before the module importer gets a chance to handle them.
        if contents.mayBeEncodedProfile {
            do {
#if !PSP_CROSS
                return try fallbackProfile(fromString: contents)
#else
                return try profile(fromJSON: contents)
#endif
            } catch {
                pspLog(.core, .debug, "Unable to decode profile for import: \(error)")
            }
        }

        // Fall back to parsing a single module
        let importedModule = try module(fromContents: contents, object: passphrase)
        return try Profile(withName: name, singleModule: importedModule)
    }
}

private extension String {
    var mayBeEncodedProfile: Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return true
        }
#if !PSP_CROSS
        return trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=").inverted) == nil
#else
        return false
#endif
    }
}
