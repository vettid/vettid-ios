import CoreGraphics
import Foundation
import ImageIO
import Testing
import VettIDCrypto
@testable import VettIDData
import VettIDDataTesting
import VettIDMedia
import VettIDVault

/// Pictures for the photo tests: drawn with Core Graphics and encoded by ImageIO with the camera's and the position's
/// metadata, as a photo from the library has them.
enum TestPhotos {
    static func picture(_ w: Int = 1_200, _ h: Int = 900) -> CGImage {
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.47, blue: 0.78, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.78, blue: 0.08, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        return ctx.makeImage()!
    }

    /// A JPEG with a GPS position, the camera's make and model, and an orientation.
    static func cameraJpeg() -> [UInt8] {
        let out = CFDataCreateMutable(nil, 0)!
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.5162, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam"],
        ]
        CGImageDestinationAddImage(dest, picture(), props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return [UInt8](out as Data)
    }

    static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        return (0...(hay.count - needle.count)).contains { i in hay[i..<(i + needle.count)].elementsEqual(needle) }
    }

    /// A JPEG, PNG or WebP signature anywhere in [b].
    static func hasImageSignature(_ b: [UInt8]) -> Bool {
        guard b.count >= 12 else { return false }
        return (0..<(b.count - 11)).contains { i in
            (b[i] == 0xFF && b[i + 1] == 0xD8 && b[i + 2] == 0xFF)
                || (b[i] == 0x89 && b[i + 1] == 0x50 && b[i + 2] == 0x4E && b[i + 3] == 0x47)
                || (b[i..<(i + 4)].elementsEqual("RIFF".utf8) && b[(i + 8)..<(i + 12)].elementsEqual("WEBP".utf8))
        }
    }
}

/// Photos end to end (VAULT-MESSAGING §10.5.1; IOS-PLAN §8 I2.4's acceptance): this phone against ``FakeVaultService``,
/// which checks the upload as the vault does and emulates the other member's vault. The sent JPEG carries no EXIF or GPS;
/// the memory cache is empty after the lock; a scan of the phone's data directory finds no image.
@MainActor
@Suite(.serialized) struct VaultManagerPhotosTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"

    init() throws {
        service = try FakeVaultService()
        phone = try TestVaultPhone(service: service, requestTimeout: TestVaultPhone.shortRequestTimeout)
    }

    var m: VaultManager { phone.manager }
    var c: ConnectionsManager { phone.manager.connections }
    var msgs: MessagesManager { phone.manager.messages }
    var att: AttachmentManager { phone.manager.attachments }

    /// Enrolled and open, connected with another member; returns the connection id.
    func connected() async throws -> String {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: "correct horse battery", backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        // The opening's reads done (the items are read last): none of them reads the conversation once it exists, which
        // would put the vault's list over a message the test has just received.
        #expect(await eventually(within: .seconds(30)) { m.items.load == .loaded })
        let r = try await c.acceptInvite(try service.peerInvite(first: "Morgan", last: "Lee", name: "Mo"))
        // Under a loaded full run the opening's reads (with this suite's short request timeout) take longer than the default.
        #expect(await eventually(within: .seconds(30)) { c.requests.first?.sas != nil })
        try service.peerApproves(r.connectionID)
        try await c.approveOutgoing(r.connectionID)
        #expect(await eventually(within: .seconds(30)) { c.connections.map(\.id) == [r.connectionID] })
        return r.connectionID
    }

    func failure(_ body: () async throws -> some Any) async -> VaultFailure? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? VaultFailure
        }
    }

    /// I2.4's first acceptance and the exit of I2 in process: a photo to the other member arrives as sent, without EXIF
    /// or GPS, and its state follows; a photo from them arrives with its thumbnail and opens.
    @Test func photosBothWaysWithThePeer() async throws {
        defer { phone.close() }
        let id = try await connected()
        #expect(await eventually { att.available }, "the probe found release A")
        let source = TestPhotos.cameraJpeg()
        #expect(TestPhotos.contains(source, Array("TestCam".utf8)))
        let prepared = try await att.prepare(source)
        let jpeg = prepared.jpeg.copy(), thumb = prepared.thumb.copy()
        let msg = try await att.send(att.begin(id, caption: "At the lake", photo: prepared))
        // What the other member's vault received is the prepared JPEG: no EXIF, no GPS, nothing of the camera.
        let delivered = try #require(service.peerPhotos(id).first)
        #expect(delivered == jpeg && !JpegSegments.hasMetadata(delivered))
        #expect(!TestPhotos.contains(delivered, Array("TestCam".utf8)) && !TestPhotos.contains(delivered, Array("Exif".utf8)))
        let src = try #require(CGImageSourceCreateWithData(Data(delivered) as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyGPSDictionary] == nil && props?[kCGImagePropertyExifDictionary] == nil)
        #expect(msgs.messages(id).map(\.messageID) == [msg.messageID] && msgs.messages(id).first?.text == "At the lake")
        #expect(await eventually { msgs.messages(id).first?.attachment?.state == .delivered })
        #expect(att.cachedThumbnail(id, messageID: msg.messageID) == thumb)
        #expect(service.vaultMailboxBlobs == 0, "the vault took the upload")

        // Opening the sent photo: a fresh blob in this phone's mailbox, fetched, checked and deleted there.
        let own = try await att.photo(id, messageID: msg.messageID)
        #expect(own.bytes.copy() == jpeg && own.type == .jpeg)
        #expect(service.deviceMailboxBlobs == 0 && service.deviceBlobsDeleted.count == 1)

        // A photo from the other member, with a name to sanitize.
        let theirs = try Photos.prepare(TestPhotos.picture(800, 600))
        let inID = try service.peerSendsPhoto(
            id, content: theirs.jpeg.copy(), thumb: theirs.thumb.copy(), width: 800, height: 600, name: "../x\u{202E}gpj.png"
        )
        // The message is listed before its photo is stored; under load the store can come a little later.
        #expect(await eventually { msgs.messages(id).last?.messageID == inID && msgs.messages(id).last?.attachment?.state == .stored })
        let incoming = try #require(msgs.messages(id).last?.attachment)
        #expect(incoming.state == .stored && incoming.name == "xgpj.png" && incoming.width == 800 && incoming.viewable)
        #expect(att.cachedThumbnail(id, messageID: inID) == theirs.thumb.copy(), "the thumbnail of message.new, in memory")
        let photo = try await att.photo(id, messageID: inID)
        let shown = try Photos.decodeReceived(photo.bytes.copy(), targetLongEdge: 1_080)
        #expect(shown.width == 800 && shown.height == 600)
        // Read again (a reload): the device view without the thumbnail, which is fetched by part.
        msgs.forgetConversation(id)
        try await msgs.load(id)
        #expect(msgs.messages(id).map { $0.attachment?.state } == [.delivered, .stored])
        att.clear()
        #expect(try await att.thumbnail(id, messageID: inID) == theirs.thumb.copy())
    }

    /// A lost answer: Retry is the same request (the vault answers it from its cache), and nothing is uploaded again.
    @Test func retryAfterALostAnswerIsTheSameRequestWithoutANewUpload() async throws {
        defer { phone.close() }
        let id = try await connected()
        let p = att.begin(id, caption: "", photo: try await att.prepare(TestPhotos.cameraJpeg()))
        service.loseAnswers(["message.send"])
        #expect(await failure { try await att.send(p) }?.kind == .noResponse)
        #expect(p.uploaded && !p.isWiped)
        service.loseAnswers([])
        let msg = try await att.send(p)
        #expect(service.photoUploads == 1)
        #expect(service.messageIDs(id) == [msg.messageID], "one message in the vault")
        #expect(service.requestsSeen.count { $0 == "message.send" } >= 2)
    }

    /// Cancel after a lost answer asks the vault to discard the upload; a full mailbox is said and not retried.
    @Test func cancelDiscardsAndAFullMailboxIsSaid() async throws {
        defer { phone.close() }
        let id = try await connected()
        let p = att.begin(id, caption: "", photo: try await att.prepare(TestPhotos.cameraJpeg()))
        service.loseAnswers(["message.send"])
        _ = await failure { try await att.send(p) }
        service.loseAnswers([])
        await att.cancel(p)
        #expect(service.discardedBlobs.count == 1 && p.isWiped)

        service.refusesPhotoUploads = "quota_exceeded"
        let q = att.begin(id, caption: "", photo: try await att.prepare(TestPhotos.cameraJpeg()))
        let e = await failure { try await att.send(q) }
        #expect(e?.kind == .limit && e?.code == AttachmentManager.codeQuota && !q.uploaded)
    }

    /// "Compatibility": a vault without release A has no photos.
    @Test func withoutReleaseAThereAreNoPhotos() async throws {
        defer { phone.close() }
        service.attachmentsReleaseA = false
        _ = try await connected()
        await att.probe()
        #expect(!att.available)
    }

    /// I2.4's acceptance: after sending, receiving, viewing and offering a share, the lock leaves the memory cache empty
    /// (thumbnails, photos, pending uploads, share offers) and nothing of a photo in the phone's data directory: no image
    /// signature, no byte run of the photo or its thumbnail, no blob id or `att_id`.
    @Test func afterTheLockTheMemoryIsEmptyAndTheDataDirectoryHasNoImage() async throws {
        defer { phone.close() }
        let id = try await connected()
        let prepared = try await att.prepare(TestPhotos.cameraJpeg())
        let jpeg = prepared.jpeg.copy(), thumb = prepared.thumb.copy()
        let msg = try await att.send(att.begin(id, caption: "caption", photo: prepared))
        let pending = att.begin(id, caption: "", photo: try await att.prepare(TestPhotos.cameraJpeg()))
        let theirs = try Photos.prepare(TestPhotos.picture(640, 480))
        let inID = try service.peerSendsPhoto(id, content: theirs.jpeg.copy(), thumb: theirs.thumb.copy())
        #expect(await eventually { msgs.messages(id).count == 2 })
        let viewed = try await att.photo(id, messageID: inID)
        _ = try await att.photo(id, messageID: msg.messageID)
        let token = SharedPhotos.shared.offer(viewed.bytes.copy(), type: viewed.type)
        #expect(att.photos.count == 2 && att.thumbs.count == 2)

        try await m.lock()
        #expect(att.cleared >= 1 && att.thumbs.count == 0 && att.photos.count == 0 && att.pending.isEmpty)
        #expect(pending.isWiped && !SharedPhotos.shared.live(token) && msgs.messages(id).isEmpty)

        let needles: [[UInt8]] = [
            Array(jpeg[(jpeg.count / 2)..<(jpeg.count / 2 + 64)]), Array(thumb[(thumb.count / 2)..<(thumb.count / 2 + 32)]),
            Array(theirs.jpeg.copy()[100..<164]),
        ] + (service.photoAttIDs + service.deviceBlobsDeleted).map { Array($0.utf8) }
        let files = FileManager.default.enumerator(at: phone.directory, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? []
        #expect(!files.isEmpty, "the phone keeps its encrypted files there")
        for f in files {
            let b = [UInt8]((try? Data(contentsOf: f)) ?? Data())
            #expect(!TestPhotos.hasImageSignature(b), "image signature in \(f.lastPathComponent)")
            for n in needles { #expect(!TestPhotos.contains(b, n), "photo, thumbnail, blob id or att_id in \(f.lastPathComponent)") }
        }
    }

    /// Held or due (§3.6.3): no photo or thumbnail is kept.
    @Test func theHoldClearsThePhotos() async throws {
        defer { phone.close() }
        let id = try await connected()
        let theirs = try Photos.prepare(TestPhotos.picture(320, 240))
        let inID = try service.peerSendsPhoto(id, content: theirs.jpeg.copy(), thumb: theirs.thumb.copy())
        #expect(await eventually { att.cachedThumbnail(id, messageID: inID) != nil })
        let before = att.cleared
        m.ownerChecks.onHeldChange(true)
        #expect(att.cleared == before + 1 && att.cachedThumbnail(id, messageID: inID) == nil)
    }
}

/// A front-camera shot (``PhotoBytes/mirrored``) is prepared mirrored, as it was previewed (vettid-android
/// `PhotoCamera.take`), through the same re-encode: no metadata, the source zeroed.
@MainActor
@Suite struct MirroredShotTests {
    /// Left half red, right half blue, as a camera JPEG with metadata.
    static func halves() -> [UInt8] {
        let ctx = CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        let out = CFDataCreateMutable(nil, 0)!
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        let props: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam"]]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return [UInt8](out as Data)
    }

    /// The red share of the left tenth of [jpeg]'s middle row.
    static func leftIsRed(_ jpeg: [UInt8]) throws -> Bool {
        let image = try Photos.decodeReceived(jpeg, targetLongEdge: 400)
        var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
        buf.withUnsafeMutableBytes { p in
            let ctx = CGContext(
                data: p.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let i = ((image.height / 2) * image.width + image.width / 10) * 4
        return buf[i] > 200 && buf[i + 2] < 60
    }

    @Test func aFrontShotIsPreparedMirroredAndClean() async throws {
        let att = AttachmentManager(ops: { throw VaultFailure(.other) })
        let plain = try await att.prepare(PhotoBytes(Self.halves()))
        #expect(try Self.leftIsRed(plain.jpeg.copy()))
        var raw = Self.halves()
        let front = PhotoBytes(taking: &raw, mirrored: true)
        #expect(raw.allSatisfy { $0 == 0 }, "the app's source copy zeroed once taken")
        let mirrored = try await att.prepare(front)
        let jpeg = mirrored.jpeg.copy()
        #expect(try !Self.leftIsRed(jpeg), "mirrored: blue on the left")
        #expect(!JpegSegments.hasMetadata(jpeg) && !TestPhotos.contains(jpeg, Array("TestCam".utf8)))
    }
}
