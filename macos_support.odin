package main
import "base:intrinsics"
import "core:sys/darwin/Foundation"

SearchPathDirectory :: enum (Foundation.UInteger) {
	ApplicationDirectory = 1, // supported applications (Applications)
	DemoApplicationDirectory, // unsupported applications, demonstration versions (Demos)
	DeveloperApplicationDirectory, // developer applications (Developer/Applications). DEPRECATED - there is no one single Developer directory.
	AdminApplicationDirectory, // system and network administration applications (Administration)
	LibraryDirectory, // various documentation, support, and configuration files, resources (Library)
	DeveloperDirectory, // developer resources (Developer) DEPRECATED - there is no one single Developer directory.
	UserDirectory, // user home directories (Users)
	DocumentationDirectory, // documentation (Documentation)
	DocumentDirectory, // documents (Documents)
	CoreServiceDirectory, // location of CoreServices directory (System/Library/CoreServices)
	AutosavedInformationDirectory  /*API_AVAILABLE(macos(10.6), ios(4.0), watchos(2.0), tvos(9.0))*/= 11, // location of autosaved documents (Documents/Autosaved)
	DesktopDirectory = 12, // location of user's desktop
	CachesDirectory = 13, // location of discardable cache files (Library/Caches)
	ApplicationSupportDirectory = 14, // location of application support files (plug-ins, etc) (Library/Application Support)
	DownloadsDirectory  /*API_AVAILABLE(macos(10.5), ios(2.0), watchos(2.0), tvos(9.0))*/= 15, // location of the user's "Downloads" directory
	InputMethodsDirectory  /*API_AVAILABLE(macos(10.6), ios(4.0), watchos(2.0), tvos(9.0))*/= 16, // input methods (Library/Input Methods)
	MoviesDirectory  /*API_AVAILABLE(macos(10.6), ios(4.0), watchos(2.0), tvos(9.0))*/= 17, // location of user's Movies directory (~/Movies)
	MusicDirectory  /*API_AVAILABLE(macos(10.6), ios(4.0), watchos(2.0), tvos(9.0))*/= 18, // location of user's Music directory (~/Music)
	PicturesDirectory  /*API_AVAILABLE(macos(10.6), ios(4.0), watchos(2.0), tvos(9.0))*/= 19, // location of user's Pictures directory (~/Pictures)
	PrinterDescriptionDirectory  /*API_AVAILABLE(macos(10.6), ios(4.0), watchos(2.0), tvos(9.0))*/= 20, // location of system's PPDs directory (Library/Printers/PPDs)
	SharedPublicDirectory  /*API_AVAILABLE(macos(10.6), ios(4.0), watchos(2.0), tvos(9.0))*/= 21, // location of user's Public sharing directory (~/Public)
	PreferencePanesDirectory  /*API_AVAILABLE(macos(10.6), ios(4.0), watchos(2.0), tvos(9.0))*/= 22, // location of the PreferencePanes directory for use with System Preferences (Library/PreferencePanes)
	ApplicationScriptsDirectory  /*API_AVAILABLE(macos(10.8)) API_UNAVAILABLE(ios, watchos, tvos)*/= 23, // location of the user scripts folder for the calling application (~/Library/Application Scripts/code-signing-id)
	ItemReplacementDirectory  /*API_AVAILABLE(macos(10.6), ios(4.0), watchos(2.0), tvos(9.0))*/= 99, // For use withFileManager's URLForDirectory:inDomain:appropriateForURL:create:error:
	AllApplicationsDirectory = 100, // all directories where applications can occur
	AllLibrariesDirectory = 101, // all directories where resources can occur
	TrashDirectory  /*API_AVAILABLE(macos(10.8), ios(11.0)) API_UNAVAILABLE(watchos, tvos)*/= 102, // location of Trash directory
}

SearchPathDomainMask :: enum (Foundation.UInteger) {
	UserDomainMask    = 1, // user's home directory --- place to install user's personal items (~)
	LocalDomainMask   = 2, // local to the current machine --- place to install items available to everyone on this machine (/Library)
	NetworkDomainMask = 4, // publicly available location in the local area network --- place to install items available on the network (/Network)
	SystemDomainMask  = 8, // provided by Apple, unmodifiable (/System)
	AllDomainsMask    = 0x0ffff, // all domains: all of the above and future items
}
msgSend :: intrinsics.objc_send
@(objc_class = "NSFileManager")
FileManager :: struct {
	using _: Foundation.Object,
}

@(objc_type = FileManager, objc_name = "defaultManager", objc_is_class_method = true)
FileManager_defaultManager :: #force_inline proc "c" () -> ^FileManager {
	return msgSend(^FileManager, FileManager, "defaultManager")
}
@(objc_type = FileManager, objc_name = "URLsForDirectory")
FileManger_URLsForDirectory :: #force_inline proc "c" (
	self: ^FileManager,
	directory: SearchPathDirectory,
	domains: SearchPathDomainMask,
) -> ^Foundation.Array {
	return msgSend(^Foundation.Array, self, "URLsForDirectory:inDomains:", directory, domains)
}
