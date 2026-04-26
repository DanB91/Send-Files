// filepath: 3rdparty/ImGuiFileDialog/ImGuiFileDialog.odin
// Odin bindings for ImGuiFileDialog v0.6.9
// https://github.com/aiekick/ImGuiFileDialog

package imguifiledialog

import im "../imgui"
import "core:c"

// Version
// VERSION :: "v0.6.9 WIP"

// ImGui types from imgui package
ImVec2 :: im.Vec2
ImVec4 :: im.Vec4
ImFont :: im.Font
ImGuiWindowFlags :: im.WindowFlags
ImGuiSelectableFlags :: im.SelectableFlags

// ============================================================
// FLAGS
// ============================================================

// File style flags for file display (color, icon, font)
FileStyleFlags :: enum c.int {
	None                  = 0, // define none style
	ByTypeFile            = (1 << 0), // define style for all files
	ByTypeDir             = (1 << 1), // define style for all dir
	ByTypeLink            = (1 << 2), // define style for all link
	ByExtention           = (1 << 3), // define style by extention, for files or links
	ByFullName            = (1 << 4), // define style for particular file/dir/link full name (filename + extention)
	ByContainedInFullName = (1 << 5), // define style for file/dir/link when criteria is contained in full name
}

// ImGuiFileDialog flags
ImGuiFileDialogFlags :: bit_set[ImGuiFileDialogFlag;c.int]
ImGuiFileDialogFlag :: enum c.int {
	// None                              = 0, // define none default flag
	ConfirmOverwrite                  = 0, // show confirm to overwrite dialog
	DontShowHiddenFiles               = 1, // dont show hidden file (file starting with a .)
	DisableCreateDirectoryButton      = 2, // disable the create directory button
	HideColumnType                    = 3, // hide column file type
	HideColumnSize                    = 4, // hide column file size
	HideColumnDate                    = 5, // hide column file date
	NoDialog                          = 6, // let the dialog embedded in your own imgui begin / end scope
	ReadOnlyFileNameField             = 7, // don't let user type in filename field for file open style dialogs
	CaseInsensitiveExtentionFiltering = 8, // the file extentions filtering will not take into account the case
	Modal                             = 9, // modal
	DisableThumbnailMode              = 10, // disable the thumbnail mode
	DisablePlaceMode                  = 11, // disable the place mode
	DisableQuickPathSelection         = 12, // disable the quick path selection
	ShowDevicesButton                 = 13, // show the devices selection button
	NaturalSorting                    = 14, // enable the antural sorting for filenames and extentions, slower than standard sorting
	OptionalFileName                  = 15, // the input filename is optional, so the dialog can be validated even if the filebname input is empty

	// Default flags
	// Default                           = ConfirmOverwrite | Modal | HideColumnType,
}
DEFAULT_IGFD_FLAGS :: ImGuiFileDialogFlags{.ConfirmOverwrite, .Modal, .HideColumnType}

// Result mode flags for GetFilePathName/GetSelection
ResultMode :: enum c.int {
	AddIfNoFileExt   = 0, // add the file ext only if there is no file ext
	OverwriteFileExt = 1, // Overwrite the file extention by the current filter
	KeepInputFile    = 2, // keep the input file => no modification
}

// ============================================================
// STRUCTURES
// ============================================================

// File dialog configuration
FileDialog_Config :: struct {
	path:                cstring, // path
	file_name:           cstring, // defaut file name
	file_path_name:      cstring, // if not empty, the filename and the path will be obtained from filePathName
	count_selection_max: i32, // count selection max, 0 for infinite
	user_datas:          rawptr, // user datas (can be retrieved in pane)
	side_pane:           PaneFun, // side pane callback
	side_pane_width:     f32, // side pane width
	flags:               ImGuiFileDialogFlags, // ImGuiFileDialogFlags
}

// Selection pair (file name + file path)
Selection_Pair :: struct {
	file_name:      cstring,
	file_path_name: cstring,
}

// Selection (multiple files)
Selection :: struct {
	table: [^]Selection_Pair,
	count: c.size_t,
}

// Thumbnail info (when USE_THUMBNAILS is defined)
Thumbnail_Info :: struct {
	is_ready_to_display:  c.int, // ready to be rendered, so texture created
	is_ready_to_upload:   c.int, // ready to upload to gpu
	is_loading_or_loaded: c.int, // was sent to loading or loaded
	texture_width:        c.int, // width of the texture to upload
	texture_height:       c.int, // height of the texture to upload
	texture_channels:     c.int, // count channels of the texture to upload
	texture_file_datas:   [^]u8, // file texture datas, will be reset to null after gpu upload
	texture_id:           rawptr, // 2d texture id (void* is like ImtextureID type)
	user_datas:           rawptr, // user datas
}

// ============================================================
// CALLBACK TYPES
// ============================================================

// Side pane callback: pane_function(user_datas: rawptr, is_valid: ^bool)
PaneFun :: #type proc "c" (pane_name: cstring, user_datas: rawptr, is_valid: ^bool)

// Thumbnail callbacks (when USE_THUMBNAILS is defined)
CreateThumbnailFun :: #type proc "c" (info: ^Thumbnail_Info)
DestroyThumbnailFun :: #type proc "c" (info: ^Thumbnail_Info)

// ============================================================
// C API
// ============================================================

// Note: These are C API bindings. The actual functions are declared as extern "C"
// in the ImGuiFileDialog header. You'll need to link against the library.
ImGuiFileDialog :: struct {}
// Config
foreign import lib "../imgui/imgui_darwin_arm64.a"
foreign lib {
	// Create and destroy
	@(link_name = "IGFD_FileDialog_Config_Get")
	FileDialog_Config_Get :: proc() -> FileDialog_Config ---
	@(link_name = "IGFD_Create")
	Create :: proc() -> ^ImGuiFileDialog ---
	@(link_name = "IGFD_Destroy")
	Destroy :: proc(ctx: ^ImGuiFileDialog) ---

	// Open/Display/Close dialog
	@(link_name = "IGFD_OpenDialog")
	OpenDialog :: proc(ctx: ^ImGuiFileDialog, key: cstring, title: cstring, filters: cstring, config: FileDialog_Config) ---

	@(link_name = "IGFD_DisplayDialog")
	DisplayDialog :: proc(ctx: ^ImGuiFileDialog, key: cstring, flags: im.WindowFlags, min_size: ImVec2, max_size: ImVec2) -> bool ---

	@(link_name = "IGFD_CloseDialog")
	CloseDialog :: proc(ctx: ^ImGuiFileDialog) ---

	// Queries
	@(link_name = "IGFD_IsOk")
	IsOk :: proc(ctx: ^ImGuiFileDialog) -> bool ---
	WasKeyOpenedThisFrame :: proc(ctx: ^ImGuiFileDialog, key: cstring) -> bool ---
	WasOpenedThisFrame :: proc(ctx: ^ImGuiFileDialog) -> bool ---
	IsKeyOpened :: proc(ctx: ^ImGuiFileDialog, current_opened_key: cstring) -> bool ---
	IsOpened :: proc(ctx: ^ImGuiFileDialog) -> bool ---

	// Get results
	@(link_name = "IGFD_GetSelection")
	GetSelection :: proc(ctx: ^ImGuiFileDialog, mode: ResultMode) -> Selection ---
	@(link_name = "IGFD_GetFilePathName")
	GetFilePathName :: proc(ctx: ^ImGuiFileDialog, mode: ResultMode) -> cstring ---
	@(link_name = "IGFD_GetCurrentFileName")
	GetCurrentFileName :: proc(ctx: ^ImGuiFileDialog, mode: ResultMode) -> cstring ---
	@(link_name = "IGFD_GetCurrentPath")
	GetCurrentPath :: proc(ctx: ^ImGuiFileDialog) -> cstring ---
	GetCurrentFilter :: proc(ctx: ^ImGuiFileDialog) -> cstring ---
	@(link_name = "IGFD_GetUserDatas")
	GetUserDatas :: proc(ctx: ^ImGuiFileDialog) -> rawptr ---

	// File style
	SetFileStyle :: proc(ctx: ^ImGuiFileDialog, flags: FileStyleFlags, filter: cstring, color: ImVec4, icon_text: cstring, font: rawptr) ---

	SetFileStyle2 :: proc(ctx: ^ImGuiFileDialog, flags: FileStyleFlags, filter: cstring, r, g, b, a: f32, icon_text: cstring, font: rawptr) ---

	GetFileStyle :: proc(ctx: ^ImGuiFileDialog, flags: FileStyleFlags, filter: cstring, out_color: ^ImVec4, out_icon_text: ^cstring, out_font: ^rawptr) -> bool ---

	ClearFilesStyle :: proc(ctx: ^ImGuiFileDialog) ---

	// Locales
	SetLocales :: proc(ctx: ^ImGuiFileDialog, category: i32, begin_locale: cstring, end_locale: cstring) ---

	// Selection helpers
	Selection_Pair_Get :: proc() -> Selection_Pair ---
	Selection_Pair_DestroyContent :: proc(pair: ^Selection_Pair) ---
	Selection_Get :: proc() -> Selection ---
	Selection_DestroyContent :: proc(selection: ^Selection) ---
}
