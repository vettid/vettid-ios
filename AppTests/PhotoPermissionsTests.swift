import Foundation
import Testing

/// The photo permissions of the app (IOS-PLAN §4 "Profile photo, photo attachments"; ANDROID-PLAN "Photo attachments":
/// no media or storage permission): photos are chosen in the system's picker, which needs no photo-library access, so
/// the app declares none; saving uses the add-only permission; the camera has its usage text.
struct PhotoPermissionsTests {
    let info = Bundle.main.infoDictionary ?? [:]

    @Test func noPhotoLibraryAccessIsDeclared() {
        #expect(info["NSPhotoLibraryUsageDescription"] == nil)
        #expect((info["NSPhotoLibraryAddUsageDescription"] as? String)?.isEmpty == false)
        #expect((info["NSCameraUsageDescription"] as? String)?.isEmpty == false)
    }
}
