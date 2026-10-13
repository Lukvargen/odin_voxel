package main

import "core:math"
import SDL "vendor:sdl3"
import TTF "vendor:sdl3/ttf"
import clay "thirdparty/clay-odin"

Clay_SDL3RendererData :: struct {
	renderer:   ^SDL.Renderer,
	textEngine: ^TTF.TextEngine,
	fonts:      [dynamic]^TTF.Font,
}

// ── Per-size font cache ──────────────────────────────────────────────────────

FONT_SIZE_CACHE_MAX :: 16

SizedFontEntry :: struct {
	font:     ^TTF.Font,
	baseFont: ^TTF.Font,
	size:     f32,
}

s_sizedFonts:      [FONT_SIZE_CACHE_MAX]SizedFontEntry
s_sizedFontCount:  int

sdl_clay_get_sized_font :: proc(baseFont: ^TTF.Font, size: f32) -> ^TTF.Font {
	for i in 0..<s_sizedFontCount {
		e := &s_sizedFonts[i]
		if e.baseFont == baseFont && e.size == size { return e.font }
	}
	copy := TTF.CopyFont(baseFont)
	if copy == nil {
		TTF.SetFontSize(baseFont, size)
		return baseFont
	}
	TTF.SetFontSize(copy, size)
	if s_sizedFontCount < FONT_SIZE_CACHE_MAX {
		s_sizedFonts[s_sizedFontCount] = SizedFontEntry{font = copy, baseFont = baseFont, size = size}
		s_sizedFontCount += 1
	}
	return copy
}

// ── TTF_Text cache ───────────────────────────────────────────────────────────

TTCACHE_MAX :: 4096

TTCacheEntry :: struct {
	text: ^TTF.Text,
	hash: u32,
	used: bool,
}

s_ttcache:      [TTCACHE_MAX]TTCacheEntry
s_ttcacheCount: int

ttcache_hash :: proc(str: []u8, fontId: u16, fontSize: u16, r, g, b, a: u8) -> u32 {
	h := u32(2166136261)
	for c in str { h = (h ~ u32(c)) * 16777619 }
	h = (h ~ u32(fontId))  * 16777619
	h = (h ~ u32(fontSize)) * 16777619
	h = (h ~ u32(r)) * 16777619
	h = (h ~ u32(g)) * 16777619
	h = (h ~ u32(b)) * 16777619
	h = (h ~ u32(a)) * 16777619
	return h
}

ttcache_begin_frame :: proc() {
	dst := 0
	for i in 0..<s_ttcacheCount {
		if s_ttcache[i].used {
			s_ttcache[i].used = false
			s_ttcache[dst] = s_ttcache[i]
			dst += 1
		} else {
			TTF.DestroyText(s_ttcache[i].text)
		}
	}
	s_ttcacheCount = dst
}

ttcache_find :: proc(hash: u32) -> ^TTF.Text {
	for i in 0..<s_ttcacheCount {
		if s_ttcache[i].hash == hash {
			s_ttcache[i].used = true
			return s_ttcache[i].text
		}
	}
	return nil
}

ttcache_insert :: proc(hash: u32, text: ^TTF.Text) {
	if s_ttcacheCount >= TTCACHE_MAX {
		victim := 0
		for i in 0..<s_ttcacheCount {
			if !s_ttcache[i].used { victim = i; break }
		}
		TTF.DestroyText(s_ttcache[victim].text)
		s_ttcache[victim] = TTCacheEntry{text = text, hash = hash, used = true}
		return
	}
	s_ttcache[s_ttcacheCount] = TTCacheEntry{text = text, hash = hash, used = true}
	s_ttcacheCount += 1
}

NUM_CIRCLE_SEGMENTS := 16

SDL_Clay_RenderFillRoundedRect :: proc(rendererData: ^Clay_SDL3RendererData, rect: SDL.FRect, cornerRadius: f32, _color: clay.Color) {
	color := SDL.FColor{
		_color.r / 255.0,
		_color.g / 255.0,
		_color.b / 255.0,
		_color.a / 255.0,
	}

	indexCount  := 0
	vertexCount := 0

	minRadius     := min(rect.w, rect.h) / 2.0
	clampedRadius := min(cornerRadius, minRadius)

	numCircleSegments := max(NUM_CIRCLE_SEGMENTS, int(clampedRadius * 0.5))

	totalVertices := 4 + (4 * (numCircleSegments * 2)) + 2 * 4
	totalIndices  := 6 + (4 * (numCircleSegments * 3)) + 6 * 4

	vertices := make([]SDL.Vertex, totalVertices, context.temp_allocator)
	indices  := make([]i32,        totalIndices,  context.temp_allocator)

	// Center rectangle
	vertices[vertexCount] = SDL.Vertex{{rect.x + clampedRadius, rect.y + clampedRadius}, color, {0, 0}}
	vertexCount += 1
	vertices[vertexCount] = SDL.Vertex{{rect.x + rect.w - clampedRadius, rect.y + clampedRadius}, color, {1, 0}}
	vertexCount += 1
	vertices[vertexCount] = SDL.Vertex{{rect.x + rect.w - clampedRadius, rect.y + rect.h - clampedRadius}, color, {1, 1}}
	vertexCount += 1
	vertices[vertexCount] = SDL.Vertex{{rect.x + clampedRadius, rect.y + rect.h - clampedRadius}, color, {0, 1}}
	vertexCount += 1

	indices[indexCount] = 0; indexCount += 1
	indices[indexCount] = 1; indexCount += 1
	indices[indexCount] = 3; indexCount += 1
	indices[indexCount] = 1; indexCount += 1
	indices[indexCount] = 2; indexCount += 1
	indices[indexCount] = 3; indexCount += 1

	// Rounded corners as triangle fans
	step := (math.PI / 2.0) / f32(numCircleSegments)

	for i in 0..<numCircleSegments {
		angle1 := f32(i) * step
		angle2 := (f32(i) + 1.0) * step

		for j in 0..<4 {
			cx, cy, signX, signY: f32
			switch j {
			case 0:
				cx = rect.x + clampedRadius
				cy = rect.y + clampedRadius
				signX = -1; signY = -1
			case 1:
				cx = rect.x + rect.w - clampedRadius
				cy = rect.y + clampedRadius
				signX =  1; signY = -1
			case 2:
				cx = rect.x + rect.w - clampedRadius
				cy = rect.y + rect.h - clampedRadius
				signX =  1; signY =  1
			case 3:
				cx = rect.x + clampedRadius
				cy = rect.y + rect.h - clampedRadius
				signX = -1; signY =  1
			case:
				return
			}

			vertices[vertexCount] = SDL.Vertex{
				{cx + math.cos(angle1) * clampedRadius * signX, cy + math.sin(angle1) * clampedRadius * signY},
				color, {0, 0},
			}
			vertexCount += 1
			vertices[vertexCount] = SDL.Vertex{
				{cx + math.cos(angle2) * clampedRadius * signX, cy + math.sin(angle2) * clampedRadius * signY},
				color, {0, 0},
			}
			vertexCount += 1

			indices[indexCount] = i32(j); indexCount += 1
			indices[indexCount] = i32(vertexCount - 2); indexCount += 1
			indices[indexCount] = i32(vertexCount - 1); indexCount += 1
		}
	}

	// Edge rectangles
	// Top
	vertices[vertexCount] = SDL.Vertex{{rect.x + clampedRadius, rect.y}, color, {0, 0}}
	vertexCount += 1
	vertices[vertexCount] = SDL.Vertex{{rect.x + rect.w - clampedRadius, rect.y}, color, {1, 0}}
	vertexCount += 1
	indices[indexCount] = 0;                    indexCount += 1
	indices[indexCount] = i32(vertexCount - 2); indexCount += 1
	indices[indexCount] = i32(vertexCount - 1); indexCount += 1
	indices[indexCount] = 1;                    indexCount += 1
	indices[indexCount] = 0;                    indexCount += 1
	indices[indexCount] = i32(vertexCount - 1); indexCount += 1

	// Right
	vertices[vertexCount] = SDL.Vertex{{rect.x + rect.w, rect.y + clampedRadius}, color, {1, 0}}
	vertexCount += 1
	vertices[vertexCount] = SDL.Vertex{{rect.x + rect.w, rect.y + rect.h - clampedRadius}, color, {1, 1}}
	vertexCount += 1
	indices[indexCount] = 1;                    indexCount += 1
	indices[indexCount] = i32(vertexCount - 2); indexCount += 1
	indices[indexCount] = i32(vertexCount - 1); indexCount += 1
	indices[indexCount] = 2;                    indexCount += 1
	indices[indexCount] = 1;                    indexCount += 1
	indices[indexCount] = i32(vertexCount - 1); indexCount += 1

	// Bottom
	vertices[vertexCount] = SDL.Vertex{{rect.x + rect.w - clampedRadius, rect.y + rect.h}, color, {1, 1}}
	vertexCount += 1
	vertices[vertexCount] = SDL.Vertex{{rect.x + clampedRadius, rect.y + rect.h}, color, {0, 1}}
	vertexCount += 1
	indices[indexCount] = 2;                    indexCount += 1
	indices[indexCount] = i32(vertexCount - 2); indexCount += 1
	indices[indexCount] = i32(vertexCount - 1); indexCount += 1
	indices[indexCount] = 3;                    indexCount += 1
	indices[indexCount] = 2;                    indexCount += 1
	indices[indexCount] = i32(vertexCount - 1); indexCount += 1

	// Left
	vertices[vertexCount] = SDL.Vertex{{rect.x, rect.y + rect.h - clampedRadius}, color, {0, 1}}
	vertexCount += 1
	vertices[vertexCount] = SDL.Vertex{{rect.x, rect.y + clampedRadius}, color, {0, 0}}
	vertexCount += 1
	indices[indexCount] = 3;                    indexCount += 1
	indices[indexCount] = i32(vertexCount - 2); indexCount += 1
	indices[indexCount] = i32(vertexCount - 1); indexCount += 1
	indices[indexCount] = 0;                    indexCount += 1
	indices[indexCount] = 3;                    indexCount += 1
	indices[indexCount] = i32(vertexCount - 1); indexCount += 1

	SDL.RenderGeometry(rendererData.renderer, nil, raw_data(vertices), i32(vertexCount), raw_data(indices), i32(indexCount))
}

SDL_Clay_RenderArc :: proc(rendererData: ^Clay_SDL3RendererData, center: SDL.FPoint, radius: f32, startAngle: f32, endAngle: f32, thickness: f32, color: clay.Color) {
	SDL.SetRenderDrawColor(rendererData.renderer,
		u8(color.r),
		u8(color.g),
		u8(color.b),
		u8(color.a))

	radStart := startAngle * (math.PI / 180.0)
	radEnd   := endAngle   * (math.PI / 180.0)

	numCircleSegments := max(NUM_CIRCLE_SEGMENTS, int(radius * 1.5))

	angleStep     := (radEnd - radStart) / f32(numCircleSegments)
	thicknessStep := f32(0.4)

	t := thicknessStep
	for t < thickness - thicknessStep {
		points := make([]SDL.FPoint, numCircleSegments + 1, context.temp_allocator)

		clampedRadius := max(radius - t, 1.0)

		for i in 0..=numCircleSegments {
			angle := radStart + f32(i) * angleStep
			points[i] = SDL.FPoint{
				math.round(center.x + math.cos(angle) * clampedRadius),
				math.round(center.y + math.sin(angle) * clampedRadius),
			}
		}

		SDL.RenderLines(rendererData.renderer, raw_data(points), i32(numCircleSegments + 1))
		t += thicknessStep
	}
}

currentClippingRectangle: SDL.Rect

SDL_Clay_RenderClayCommands :: proc(rendererData: ^Clay_SDL3RendererData, rcommands: ^clay.ClayArray(clay.RenderCommand)) {
	ttcache_begin_frame()
	for i in 0..<rcommands.length {
		rcmd         := clay.RenderCommandArray_Get(rcommands, i)
		bounding_box := rcmd.boundingBox
		rect := SDL.FRect{
			x = f32(int(bounding_box.x)),
			y = f32(int(bounding_box.y)),
			w = f32(int(bounding_box.width)),
			h = f32(int(bounding_box.height)),
		}

		#partial switch rcmd.commandType {
		case .Rectangle:
			config := &rcmd.renderData.rectangle
			SDL.SetRenderDrawBlendMode(rendererData.renderer, {.BLEND})
			SDL.SetRenderDrawColor(rendererData.renderer,
				u8(config.backgroundColor.r),
				u8(config.backgroundColor.g),
				u8(config.backgroundColor.b),
				u8(config.backgroundColor.a),
			)
			if config.cornerRadius.topLeft > 0 {
				SDL_Clay_RenderFillRoundedRect(rendererData, rect, config.cornerRadius.topLeft, config.backgroundColor)
			} else {
				SDL.RenderFillRect(rendererData.renderer, &rect)
			}

		case .Text:
			config := &rcmd.renderData.text
			font   := rendererData.fonts[config.fontId]
			if font == nil { continue }
			sizedFont := sdl_clay_get_sized_font(font, f32(config.fontSize))
			if sizedFont == nil { continue }
			str_bytes := transmute([]u8)string(config.stringContents.chars[:config.stringContents.length])
			hash := ttcache_hash(str_bytes,
				u16(config.fontId), u16(config.fontSize),
				u8(config.textColor.r), u8(config.textColor.g),
				u8(config.textColor.b), u8(config.textColor.a))
			text := ttcache_find(hash)
			if text == nil {
				text = TTF.CreateText(rendererData.textEngine, sizedFont,
					config.stringContents.chars,
					uint(config.stringContents.length))
				if text == nil { continue }
				TTF.SetTextColor(text,
					u8(config.textColor.r), u8(config.textColor.g),
					u8(config.textColor.b), u8(config.textColor.a))
				ttcache_insert(hash, text)
			}
			TTF.DrawRendererText(text, rect.x, rect.y)

		case .Border:
			config := &rcmd.renderData.border

			minRadius := min(rect.w, rect.h) / 2.0
			clampedRadii := clay.CornerRadius{
				topLeft     = min(config.cornerRadius.topLeft,     minRadius),
				topRight    = min(config.cornerRadius.topRight,    minRadius),
				bottomLeft  = min(config.cornerRadius.bottomLeft,  minRadius),
				bottomRight = min(config.cornerRadius.bottomRight, minRadius),
			}

			SDL.SetRenderDrawColor(rendererData.renderer,
				u8(config.color.r),
				u8(config.color.g),
				u8(config.color.b),
				u8(config.color.a))

			if config.width.left > 0 {
				startingY := rect.y + clampedRadii.topLeft
				length    := rect.h - clampedRadii.topLeft - clampedRadii.bottomLeft
				line := SDL.FRect{rect.x - 1, startingY, f32(config.width.left), length}
				SDL.RenderFillRect(rendererData.renderer, &line)
			}
			if config.width.right > 0 {
				startingX := rect.x + rect.w - f32(config.width.right) + 1
				startingY := rect.y + clampedRadii.topRight
				length    := rect.h - clampedRadii.topRight - clampedRadii.bottomRight
				line := SDL.FRect{startingX, startingY, f32(config.width.right), length}
				SDL.RenderFillRect(rendererData.renderer, &line)
			}
			if config.width.top > 0 {
				startingX := rect.x + clampedRadii.topLeft
				length    := rect.w - clampedRadii.topLeft - clampedRadii.topRight
				line := SDL.FRect{startingX, rect.y - 1, length, f32(config.width.top)}
				SDL.RenderFillRect(rendererData.renderer, &line)
			}
			if config.width.bottom > 0 {
				startingX := rect.x + clampedRadii.bottomLeft
				startingY := rect.y + rect.h - f32(config.width.bottom) + 1
				length    := rect.w - clampedRadii.bottomLeft - clampedRadii.bottomRight
				line := SDL.FRect{startingX, startingY, length, f32(config.width.bottom)}
				SDL.RenderFillRect(rendererData.renderer, &line)
			}

			// Corners
			if config.cornerRadius.topLeft > 0 {
				SDL_Clay_RenderArc(rendererData, {rect.x + clampedRadii.topLeft - 1, rect.y + clampedRadii.topLeft - 1},
					clampedRadii.topLeft, 180.0, 270.0, f32(config.width.top), config.color)
			}
			if config.cornerRadius.topRight > 0 {
				SDL_Clay_RenderArc(rendererData, {rect.x + rect.w - clampedRadii.topRight, rect.y + clampedRadii.topRight - 1},
					clampedRadii.topRight, 270.0, 360.0, f32(config.width.top), config.color)
			}
			if config.cornerRadius.bottomLeft > 0 {
				SDL_Clay_RenderArc(rendererData, {rect.x + clampedRadii.bottomLeft - 1, rect.y + rect.h - clampedRadii.bottomLeft},
					clampedRadii.bottomLeft, 90.0, 180.0, f32(config.width.bottom), config.color)
			}
			if config.cornerRadius.bottomRight > 0 {
				SDL_Clay_RenderArc(rendererData, {rect.x + rect.w - clampedRadii.bottomRight, rect.y + rect.h - clampedRadii.bottomRight},
					clampedRadii.bottomRight, 0.0, 90.0, f32(config.width.bottom), config.color)
			}

		case .ScissorStart:
			bb := rcmd.boundingBox
			currentClippingRectangle = SDL.Rect{
				x = i32(bb.x),
				y = i32(bb.y),
				w = i32(bb.width),
				h = i32(bb.height),
			}
			SDL.SetRenderClipRect(rendererData.renderer, &currentClippingRectangle)

		case .ScissorEnd:
			SDL.SetRenderClipRect(rendererData.renderer, nil)

		case .Image:
			texture := (^SDL.Texture)(rcmd.renderData.image.imageData)
			dest    := SDL.FRect{rect.x, rect.y, rect.w, rect.h}
			SDL.RenderTexture(rendererData.renderer, texture, nil, &dest)

		case .Custom:
			// Custom element rendering - add your own here

		case:
			SDL.Log("Unknown render command type: %d", rcmd.commandType)
		}
	}
}
