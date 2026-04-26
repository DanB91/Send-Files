package imgui_example_sdl3_ 

// This is an example of using the bindings with SDL3 and ...
// Based on the above at tag `v1.92.4-docking` (e7d2d63)

DISABLE_DOCKING :: #config(DISABLE_DOCKING, false)

#assert(ODIN_OS == .TARGET_OS)

import im "../.."
import "../../your_renderer_here"
import "../../imgui_impl_sdl3"

import sdl "vendor:sdl3"

main :: proc() {
	im.CHECKVERSION()
	im.CreateContext()
	defer im.DestroyContext()
	io := im.GetIO()
	io.ConfigFlags += {.NavEnableKeyboard, .NavEnableGamepad}
	when !DISABLE_DOCKING {
		io.ConfigFlags += {.DockingEnable}
		io.ConfigFlags += {.ViewportsEnable}

		style := im.GetStyle()
		style.WindowRounding = 0
		style.Colors[im.Col.WindowBg].w = 1
	}
	im.StyleColorsDark()

	sdlInitialized := sdl.Init({.VIDEO, .GAMEPAD})
	assert(sdlInitialized)
	defer sdl.Quit()

	title :: "Dear ImGui SDL3+Metal example"
	screenCoords := i64(sdl.WINDOWPOS_CENTERED)

	windowProps := sdl.CreateProperties()
	sdl.SetStringProperty(windowProps, sdl.PROP_WINDOW_CREATE_TITLE_STRING, title)
	sdl.SetNumberProperty(windowProps, sdl.PROP_WINDOW_CREATE_X_NUMBER, screenCoords)
	sdl.SetNumberProperty(windowProps, sdl.PROP_WINDOW_CREATE_Y_NUMBER, screenCoords)
	sdl.SetNumberProperty(windowProps, sdl.PROP_WINDOW_CREATE_WIDTH_NUMBER, 1280)
	sdl.SetNumberProperty(windowProps, sdl.PROP_WINDOW_CREATE_HEIGHT_NUMBER, 720)
	sdl.SetBooleanProperty(windowProps, sdl.PROP_WINDOW_CREATE_RESIZABLE_BOOLEAN, true)

	// API-specific window properties go here

	window := sdl.CreateWindowWithProperties(windowProps)
	assert(window != nil)
	defer sdl.DestroyWindow(window)

	rendererProps := sdl.CreateProperties()
	sdl.SetPointerProperty(rendererProps, sdl.PROP_RENDERER_CREATE_WINDOW_POINTER, window)
	sdl.SetBooleanProperty(rendererProps, sdl.PROP_RENDERER_CREATE_PRESENT_VSYNC_NUMBER, true)

	renderer := sdl.CreateRendererWithProperties(rendererProps)
	assert(renderer != nil)
	defer sdl.DestroyRenderer(renderer)

	// Set up your renderer

	imgui_impl_sdl3.InitForPLATFORM(window)
	defer imgui_impl_sdl3.Shutdown()

	running := true

	for running {
		// Frame implementations differ by renderers
		e: sdl.Event
		for sdl.PollEvent(&e) {
			imgui_impl_sdl3.ProcessEvent(&e)

			#partial switch e.type {
			case .QUIT:
				running = false
			}
		}

		width, height: i32
		sizeReturned := sdl.GetCurrentRenderOutputSize(renderer, &width, &height)
		assert(sizeReturned)

		imgui_impl_sdl3.NewFrame()
		im.NewFrame()

		im.ShowDemoWindow()

		if im.Begin("Window containing a quit button") {
			if im.Button("The quit button in question") {
				running = false
			}
		}
		im.End()

		im.Render()

		when !DISABLE_DOCKING {
			im.UpdatePlatformWindows()
			im.RenderPlatformWindowsDefault()
		}
	}
}
