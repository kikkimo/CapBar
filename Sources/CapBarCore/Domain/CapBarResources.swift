import Foundation

enum CapBarResources {
    static func url(forResource name: String, withExtension extensionName: String) -> URL? {
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent("CapBar_CapBarCore.bundle")),
           let url = bundle.url(forResource: name, withExtension: extensionName) {
            return url
        }
        return Bundle.module.url(forResource: name, withExtension: extensionName)
    }
}
