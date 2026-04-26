package imgui_example_sdl3_metal

// This is an example of using the bindings with SDL3 and Metal
// For a more complete example with comments, see:
// https://github.com/ocornut/imgui/blob/master/examples/example_sdl3_metal/main.mm
// Based on the above at tag `v1.92.4-docking` (e7d2d63)

// WARNING:
// This has been tested and is now working, but as an OjbC noob, the code is probably pretty bad.

DISABLE_DOCKING :: #config(DISABLE_DOCKING, false)

#assert(ODIN_OS == .Darwin)

import im "../.."
import "../../imgui_impl_metal"
import "../../imgui_impl_sdl3"

import NS "core:sys/darwin/Foundation"

import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"
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

	// API-specific
	sdl.SetBooleanProperty(windowProps, sdl.PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN, true)
	sdl.SetBooleanProperty(windowProps, sdl.PROP_WINDOW_CREATE_METAL_BOOLEAN, true)

	window := sdl.CreateWindowWithProperties(windowProps)
	assert(window != nil)
	defer sdl.DestroyWindow(window)

	rendererProps := sdl.CreateProperties()
	sdl.SetPointerProperty(rendererProps, sdl.PROP_RENDERER_CREATE_WINDOW_POINTER, window)
	sdl.SetBooleanProperty(rendererProps, sdl.PROP_RENDERER_CREATE_PRESENT_VSYNC_NUMBER, true)

	renderer := sdl.CreateRendererWithProperties(rendererProps)
	assert(renderer != nil)
	defer sdl.DestroyRenderer(renderer)

	layer := cast(^CA.MetalLayer)sdl.GetRenderMetalLayer(renderer)
	assert(layer != nil)
	layer->setPixelFormat(.BGRA8Unorm)

	imgui_impl_metal.Init(layer->device())
	defer imgui_impl_metal.Shutdown()
	imgui_impl_sdl3.InitForMetal(window)
	defer imgui_impl_sdl3.Shutdown()

	command_queue := layer->device()->newCommandQueue()
	pass: ^MTL.RenderPassDescriptor = MTL.RenderPassDescriptor.alloc()->init()

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

		width, height: i32
		sizeReturned := sdl.GetCurrentRenderOutputSize(renderer, &width, &height)
		assert(sizeReturned)

		layer->setDrawableSize(NS.Size{NS.Float(width), NS.Float(height)})
		drawable := layer->nextDrawable()

		command_buffer := command_queue->commandBuffer()
		color_attachment := pass->colorAttachments()->object(0)
		color_attachment->setClearColor(MTL.ClearColor{0, 0, 0, 1})
		color_attachment->setTexture(drawable->texture())
		color_attachment->setLoadAction(.Clear)
		color_attachment->setStoreAction(.Store)

		render_encoder := command_buffer->renderCommandEncoderWithDescriptor(pass)

		imgui_impl_metal.NewFrame(pass)
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
		imgui_impl_metal.RenderDrawData(im.GetDrawData(), command_buffer, render_encoder)

		when !DISABLE_DOCKING {
			im.UpdatePlatformWindows()
			im.RenderPlatformWindowsDefault()
		}

		render_encoder->endEncoding()

		command_buffer->presentDrawable(drawable)
		command_buffer->commit()
	}
}
