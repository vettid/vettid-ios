import Foundation
import Testing
import VettIDData
import VettIDDataTesting
import VettIDMedia
@testable import VettIDMessages

/// The photos of a conversation and the viewer (VAULT-MESSAGING §10.5.1; ANDROID-PLAN "Photo attachments"): picks
/// prepared one at a time, sent one after another with the caption on the first, Retry as the same request, Cancel with a
/// discard and not while a request is on its way, a full mailbox and a full vault said apart, and everything dropped at a
/// clear. Mirrors the photo tests of vettid-android `MessagesViewModelsTest` and `PhotoLabelTest`'s states.
@MainActor
@Suite struct PhotoViewModelTests {
    let messages = FakeMessages()
    let connections = FakeConnections()
    let attachments = FakeAttachments()

    init() {
        connections.connections = [Samples.connection("c1")]
        messages.connections = connections.connections
    }

    func conversation() async -> ConversationViewModel {
        let m = ConversationViewModel(connectionID: "c1", messages: messages, connections: connections, attachments: attachments)
        await m.settle()
        return m
    }

    func picks(_ b: [UInt8]...) -> [ConversationViewModel.PhotoSource] { b.map { x in { x } } }

    @Test func pickedPhotosAreSentOneByOneWithTheCaptionOnTheFirst() async throws {
        let vm = await conversation()
        #expect(vm.state.photosAvailable)
        vm.onPicked(picks([1], [2]))
        #expect(vm.state.photoDraft?.preparing == true)
        await vm.settle()
        #expect(vm.state.photoDraft?.photos.count == 2 && vm.state.photoDraft?.canSend == true)
        vm.setPhotoCaption("  look  ")
        vm.sendPhotos()
        await vm.settle()
        #expect(vm.state.photoDraft == nil)
        let sends = attachments.calls.filter { $0.hasPrefix("begin") || $0.hasPrefix("send") }
        #expect(sends == ["begin:look", "send:REQ1", "begin:", "send:REQ2"])
    }

    @Test func retryAfterALostAnswerReSendsTheSameRequest() async throws {
        let vm = await conversation()
        vm.onPicked(picks([1]))
        await vm.settle()
        attachments.fail["send"] = VaultFailure(.noResponse)
        vm.sendPhotos()
        await vm.settle()
        let d = try #require(vm.state.photoDraft)
        #expect(d.retry && d.problem == .noAnswer && !d.sending && !d.inFlight)
        vm.sendPhotos() // Retry
        await vm.settle()
        #expect(vm.state.photoDraft == nil)
        #expect(attachments.calls.filter { $0.hasPrefix("send") } == ["send:REQ1", "send:REQ1"])
        #expect(attachments.calls.count { $0.hasPrefix("begin") } == 1)
    }

    @Test func cancelAfterALostAnswerCancelsTheUpload() async {
        let vm = await conversation()
        vm.onPicked(picks([1]))
        await vm.settle()
        attachments.fail["send"] = VaultFailure(.noResponse)
        vm.sendPhotos()
        await vm.settle()
        vm.cancelPhotos()
        await vm.settle()
        #expect(vm.state.photoDraft == nil)
        #expect(attachments.calls.last == "abandon:REQ1") // the discard runs outside the screen's work
    }

    @Test func aFullVaultAndAFullMailboxAreSaidApart() async {
        let vm = await conversation()
        vm.onPicked(picks([1]))
        await vm.settle()
        attachments.fail["send"] = VaultFailure(.limit, code: AttachmentManager.codeQuota)
        vm.sendPhotos()
        await vm.settle()
        #expect(vm.state.photoDraft?.problem == .mailboxFull)
        #expect(vm.state.photoDraft?.photos.count == 1, "the photo stays for Send again")
        attachments.fail["send"] = VaultFailure(.limit, code: "limit")
        vm.sendPhotos()
        await vm.settle()
        #expect(vm.state.photoDraft?.problem == .vaultFull)
    }

    @Test func anUnreadablePictureIsSaid() async {
        let vm = await conversation()
        vm.onPicked(picks([]))
        await vm.settle()
        #expect(vm.state.photoDraft?.problem == .unreadable && vm.state.photoDraft?.canSend == false)
        vm.dismissPhotoProblem()
        #expect(vm.state.photoDraft == nil)
    }

    @Test func withoutReleaseAThereIsNoPhotoButton() async {
        attachments.available = false
        let vm = await conversation()
        #expect(!vm.state.photosAvailable)
        let plain = ConversationViewModel(connectionID: "c1", messages: messages, connections: connections)
        await plain.settle()
        #expect(!plain.state.photosAvailable)
    }

    @Test func cancelWaitsWhileARequestIsOnItsWayAndNoFurtherPhotoIsBegun() async {
        let vm = await conversation()
        vm.onPicked(picks([1], [2]))
        await vm.settle()
        let gate = TestDeferred<Void>()
        attachments.sendGate = gate
        vm.sendPhotos()
        for _ in 0..<5 { await Task.yield() }
        #expect(vm.state.photoDraft?.inFlight == true)
        vm.cancelPhotos() // refused while the request is on its way
        #expect(vm.state.photoDraft != nil)
        attachments.sendGate = nil
        gate.complete()
        await vm.settle()
        // The first photo was answered; the loop went on to the second (no cancel happened).
        #expect(vm.state.photoDraft == nil)
        #expect(attachments.calls.count { $0.hasPrefix("begin") } == 2)
    }

    @Test func aFinalRefusalBetweenPhotosAndACancelStopTheLoop() async throws {
        let vm = await conversation()
        vm.onPicked(picks([1], [2], [3]))
        await vm.settle()
        attachments.fail["send"] = VaultFailure(.limit, code: "limit") // the first is refused for good
        vm.sendPhotos()
        await vm.settle()
        let left = try #require(vm.state.photoDraft?.photos)
        #expect(left.count == 2)
        vm.cancelPhotos()
        await vm.settle()
        #expect(vm.state.photoDraft == nil)
        #expect(attachments.calls.count { $0.hasPrefix("begin") } == 1)
        #expect(left.allSatisfy { $0.isWiped })
    }

    @Test func aClearDropsTheDraftAndTheCamera() async throws {
        let vm = await conversation()
        vm.onPicked(picks([5]))
        await vm.settle()
        let draft = try #require(vm.state.photoDraft?.photos)
        vm.startCapture()
        attachments.clear() // a lock, the hold or due state
        await vm.settle()
        #expect(await eventually { vm.state.photoDraft == nil })
        #expect(vm.state.photoGeneration == 1 && !vm.state.capturing)
        #expect(draft.allSatisfy { $0.isWiped })
    }

    @Test func picksThatFailAreCountedAndTheOthersKept() async {
        let vm = await conversation()
        vm.onPicked([{ [1] }, { nil }, { [] }])
        await vm.settle()
        #expect(vm.state.photoDraft?.photos.count == 1 && vm.state.photoDraft?.failedPicks == 2)
    }

    @Test func aCancelWhilePicksArePreparedWipesWhatWasReady() async {
        let vm = await conversation()
        let never = TestDeferred<[UInt8]?>()
        vm.onPicked([{ [7, 7] }, { @MainActor in (try? await never.value()) ?? nil }])
        #expect(await eventually { attachments.prepared.count == 1 })
        vm.cancelPhotos()
        await vm.settle()
        #expect(vm.state.photoDraft == nil)
        #expect(attachments.prepared.first?.isWiped == true)
    }

    @Test func aShotFromTheCameraIsPrepared() async {
        let vm = await conversation()
        vm.startCapture()
        vm.onShot([9, 9, 9])
        #expect(!vm.state.capturing)
        await vm.settle()
        #expect(vm.state.photoDraft?.photos.count == 1 && vm.state.photoDraft?.failedPicks == 0)
    }

    @Test func leavingTheConversationAbandonsTheUploadAndWipesThePhotos() async throws {
        var vm: ConversationViewModel? = await conversation()
        vm?.onPicked(picks([1]))
        await vm?.settle()
        attachments.fail["send"] = VaultFailure(.noResponse)
        vm?.sendPhotos()
        await vm?.settle()
        let draft = try #require(vm?.state.photoDraft?.photos)
        vm = nil
        #expect(await eventually { attachments.calls.last == "abandon:REQ1" })
        #expect(draft.allSatisfy { $0.isWiped })
    }

    @Test func aThumbnailIsAskedWhenNotInMemory() async {
        let vm = await conversation()
        #expect(await vm.thumbnail("m1") == attachments.served)
        attachments.fail["thumbnail"] = VaultFailure(.network)
        #expect(await vm.thumbnail("m1") == nil)
    }

    // MARK: - The viewer

    @Test func theViewerShowsThePhotoWithItsSanitizedName() async {
        var m = Samples.message("m1")
        m.attachment = AttachmentInfo(attID: "a1", state: .stored, name: "x.png")
        messages.byConnection = ["c1": [m]]
        let shared = SharedPhotos()
        let vm = PhotoViewerViewModel(connectionID: "c1", messageID: "m1", attachments: attachments, messages: messages, shared: shared)
        await vm.settle()
        #expect(!vm.state.loading && vm.state.photo?.intact == true && vm.state.name == "x.png")
    }

    @Test func theViewerDropsItsPhotoAtAClearAndWipedBytesCannotLeave() async throws {
        let shared = SharedPhotos()
        let vm = PhotoViewerViewModel(connectionID: "c1", messageID: "m1", attachments: attachments, messages: messages, shared: shared)
        await vm.settle()
        let photo = try #require(vm.state.photo)
        #expect(photo.intact)
        attachments.clear()
        #expect(await eventually { vm.state.photo == nil })
        #expect(!photo.intact && vm.state.problem == .unavailable)
    }

    @Test func theViewerSaysWhyAPhotoDidNotOpen() async {
        for (code, problem) in [
            (AttachmentManager.codeType, PhotoViewerProblem.type), (AttachmentManager.codeBad, .bad), ("unavailable", .unavailable),
            ("busy", .busy), ("other", nil),
        ] {
            attachments.fail["photo"] = VaultFailure(.other, code: code)
            let vm = PhotoViewerViewModel(
                connectionID: "c1", messageID: "m1", attachments: attachments, messages: messages, shared: SharedPhotos()
            )
            await vm.settle()
            #expect(vm.state.problem == problem && vm.state.error == .other && vm.state.photo == nil, "\(code)")
            attachments.fail = [:]
            vm.load()
            await vm.settle()
            #expect(vm.state.photo != nil && vm.state.error == nil)
        }
    }

    /// The viewer gone, its share offers are withdrawn and its photo zeroed.
    @Test func leavingTheViewerWithdrawsItsShareOffers() async throws {
        let shared = SharedPhotos()
        var vm: PhotoViewerViewModel? = PhotoViewerViewModel(
            connectionID: "c1", messageID: "m1", attachments: attachments, messages: messages, shared: shared
        )
        await vm?.settle()
        let photo = try #require(vm?.state.photo)
        let token = shared.offer(photo.bytes.copy(), type: photo.type)
        vm = nil
        #expect(!shared.live(token) && !photo.intact)
    }

    // MARK: - The bubble's line

    @Test func theBubbleSaysEachStateAndReason() {
        func s(_ state: AttachmentState, _ reason: String? = nil, out: Bool) -> PhotoStatus? {
            PhotoStatus.of(AttachmentInfo(attID: "a", state: state, reason: reason), outgoing: out)
        }
        #expect(s(.preparing, out: true) == PhotoStatus(.sending) && s(.sending, out: true) == PhotoStatus(.sending))
        #expect(s(.delivered, out: true) == PhotoStatus(.delivered) && s(.fetching, out: false) == PhotoStatus(.receiving))
        #expect(s(.stored, out: false) == nil && s(.unknown, out: false) == nil)
        #expect(s(.failed, "bad", out: true) == PhotoStatus(.notSentBubble, failed: true))
        #expect(s(.failed, "type", out: true) == PhotoStatus(.notSentBubble, failed: true))
        #expect(s(.failed, "unsupported", out: true) == PhotoStatus(.peerNoPhotos, withName: true, failed: true))
        #expect(s(.failed, "unconfirmed", out: true) == PhotoStatus(.unconfirmed, failed: true))
        #expect(s(.failed, "refused:rate", out: true) == PhotoStatus(.notDelivered, failed: true))
        #expect(s(.failed, "full", out: false) == PhotoStatus(.inFull, failed: true))
        #expect(s(.failed, "rate", out: false) == PhotoStatus(.inRate, withName: true, failed: true))
        #expect(s(.failed, "type", out: false) == PhotoStatus(.inType, failed: true))
        #expect(s(.failed, "withdrawn:deleted", out: false) == PhotoStatus(.inWithdrawn, withName: true, failed: true))
        #expect(s(.failed, "expired", out: false) == PhotoStatus(.inNever, failed: true))
        #expect(AttachmentInfo(attID: "a", state: .fetching).viewable == false && AttachmentInfo(attID: "a", state: .delivered).viewable)
    }

    @Test func aPictureThatCannotBeSentSaysWhy() {
        #expect(PhotoProblem.of(.tooLarge) == .tooLarge && PhotoProblem.of(.unsupported) == .unsupported)
        #expect(PhotoProblem.of(.unreadable) == .unreadable && PhotoProblem.of(.cannotFit) == .unreadable)
        var d = PhotoDraft(photos: [PreparedPhoto(jpeg: [1], thumb: [1], width: 1, height: 1)])
        d.caption = String(repeating: "a", count: MessageLimits.maxTextBytes + 1)
        #expect(!d.canSend)
        #expect(!String(describing: d).contains("aaaa"))
    }
}

/// Waits until [condition] holds, at most [within].
@MainActor
func eventually(within: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: within)
    while clock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
