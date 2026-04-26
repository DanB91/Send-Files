package imgui_example_sdl3_opengl3

// This is an example of using the bindings with SDL3 and OpenGL 3.
// For a more complete example with comments, see:
// https://github.com/ocornut/imgui/blob/docking/examples/example_sdl3_opengl3/main.cpp
// Based on the above at tag `v1.92.4-docking` (e7d2d63)

DISABLE_DOCKING :: #config(DISABLE_DOCKING, false)

import im "../.."
import "../../imgui_impl_opengl3"
import "../../imgui_impl_sdl3"

import gl "vendor:OpenGL"
import sdl "vendor:sdl3"

main :: proc() {
	sdlInitialized := sdl.Init({.VIDEO, .GAMEPAD})
	assert(sdlInitialized)
	defer sdl.Quit()

	title :: "Dear ImGui SDL3+OpenGL example"
	screenCoords := i64(sdl.WINDOWPOS_CENTERED)

	windowProps := sdl.CreateProperties()
	sdl.SetStringProperty(windowProps, sdl.PROP_WINDOW_CREATE_TITLE_STRING, title)
	sdl.SetNumberProperty(windowProps, sdl.PROP_WINDOW_CREATE_X_NUMBER, screenCoords)
	sdl.SetNumberProperty(windowProps, sdl.PROP_WINDOW_CREATE_Y_NUMBER, screenCoords)
	sdl.SetNumberProperty(windowProps, sdl.PROP_WINDOW_CREATE_WIDTH_NUMBER, 1280)
	sdl.SetNumberProperty(windowProps, sdl.PROP_WINDOW_CREATE_HEIGHT_NUMBER, 720)
	sdl.SetBooleanProperty(windowProps, sdl.PROP_WINDOW_CREATE_RESIZABLE_BOOLEAN, true)

	sdl.SetBooleanProperty(windowProps, sdl.PROP_WINDOW_CREATE_OPENGL_BOOLEAN, true)
	sdl.SetBooleanProperty(windowProps, sdl.PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN, true)
	// OpenGL 3.2 here, see the cpp example for more configurations
	sdl.GL_SetAttribute(.CONTEXT_FLAGS, i32(sdl.GL_CONTEXT_FORWARD_COMPATIBLE_FLAG))
	sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(sdl.GL_CONTEXT_PROFILE_CORE))
	sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 2)
	
	sdl.GL_SetAttribute(.DOUBLEBUFFER, 1)
	sdl.GL_SetAttribute(.DEPTH_SIZE, 24)
	sdl.GL_SetAttribute(.STENCIL_SIZE, 8)

	window := sdl.CreateWindowWithProperties(windowProps)
	assert(window != nil, string(sdl.GetError()))
	defer sdl.DestroyWindow(window)

	gl_ctx := sdl.GL_CreateContext(window)
	assert(gl_ctx != nil, string(sdl.GetError()))
	defer sdl.GL_DestroyContext(gl_ctx)

	sdl.GL_MakeCurrent(window, gl_ctx)
	sdl.GL_SetSwapInterval(1) // vsync

	gl.load_up_to(3, 2, proc(p: rawptr, name: cstring) {
		(cast(^sdl.FunctionPointer)p)^ = sdl.GL_GetProcAddress(name)
	})

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

	imgui_impl_sdl3.InitForOpenGL(window, gl_ctx)
	defer imgui_impl_sdl3.Shutdown()
	imgui_impl_opengl3.Init(nil)
	defer imgui_impl_opengl3.Shutdown()

	running := true

	for running {
		e: sdl.Event
		for sdl.PollEvent(&e) {
			imgui_impl_sdl3.ProcessEvent(&e)

			#partial switch e.type {
			case .QUIT:
				running = false
			}
		}

		imgui_impl_opengl3.NewFrame()
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
		width := i32(io.DisplaySize.x)
		height := i32(io.DisplaySize.y)
		gl.Viewport(0, 0, width, height)
		gl.ClearColor(0, 0, 0, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		imgui_impl_opengl3.RenderDrawData(im.GetDrawData())

		when !DISABLE_DOCKING {
			backup_current_window := sdl.GL_GetCurrentWindow()
			backup_current_context := sdl.GL_GetCurrentContext()
			im.UpdatePlatformWindows()
			im.RenderPlatformWindowsDefault()
			sdl.GL_MakeCurrent(backup_current_window, backup_current_context)
		}

		sdl.GL_SwapWindow(window)
	}
}
