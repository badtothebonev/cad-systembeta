--[[
		DXUT for Moonloader
		Version: 2.0
		Author: https://blast.hk/members/11825/
		
		Special for BlastHack.Net
]]

local ffi = require'ffi'
local C = ffi.C
ffi.cdef[[
	typedef unsigned long DWORD;
	typedef long HRESULT;
	typedef struct {
		DWORD dwSize;
		DWORD dwFlags;
		DWORD dwFourCC;
		DWORD dwRGBBitCount;
		DWORD dwRBitMask;
		DWORD dwGBitMask;
		DWORD dwBBitMask;
		DWORD dwABitMask;
	} DDS_PIXELFORMAT;
	typedef struct {
		DWORD           dwSize;
		DWORD           dwFlags;
		DWORD           dwHeight;
		DWORD           dwWidth;
		DWORD           dwPitchOrLinearSize;
		DWORD           dwDepth;
		DWORD           dwMipMapCount;
		DWORD           dwReserved1[11];
		DDS_PIXELFORMAT ddspf;
		DWORD           dwCaps;
		DWORD           dwCaps2;
		DWORD           dwCaps3;
		DWORD           dwCaps4;
		DWORD           dwReserved2;
	} DDS_HEADER;
	typedef struct IDirect3DDevice9 IDirect3DDevice9;
	typedef struct IDirect3DTexture9 IDirect3DTexture9;
	struct sD3DLOCKED_RECT {
		int Pitch;
		void *pBits;
	};
	long D3DXCreateTextureFromFileInMemory(IDirect3DDevice9 *pDevice, const void *pSrcData, unsigned int SrcDataSize, IDirect3DTexture9 **ppTexture);
	long D3DXCreateTexture(IDirect3DDevice9* pDevice, unsigned int Width, unsigned int Height, unsigned int MipLevels, unsigned long Usage, int Fmt, int Pool, IDirect3DTexture9** ppTexture);
]]

local d3d9_device = ffi.cast('IDirect3DDevice9**', 0xC97C28)[0]
local dxut = {
	font = {},
	texture = {},
	render = {
		QUAD_LIST = 4,
		TRIANGLE_LIST = 4,
		TRIANGLE_STRIP = 5,
		TRIANGLE_FAN = 6,
		LINE_LIST = 2,
		LINE_STRIP = 3,
		POINT_LIST = 1,
	}
}
local ev = {
	LOST = 1,
	RESET = 2,
	RELEASE = 3,
	CREATE = 4
}

-- Private
local events = {}
local fonts = {}
local textures = {}
local vertex_buffer = {}
local FVF_TEXTURE = bit.bor(0x002, 0x004, 0x100)
local FVF_NOTEXTURE = bit.bor(0x002, 0x004)
local VERTEX_TEXTURE_SIZE = ffi.sizeof('float[3]') + ffi.sizeof('unsigned long') + ffi.sizeof('float[2]')
local VERTEX_NOTEXTURE_SIZE = ffi.sizeof('float[3]') + ffi.sizeof('unsigned long')
local memory_texture = {}
local memory_font = {}
local function callEvent(event, ...)
	if events[event] then
		for k, v in ipairs(events[event]) do
			v(...)
		end
	end
end

-- Class
function dxut:__init(event, func)
	if not events[event] then events[event] = {} end
	table.insert(events[event], func)
end

function dxut.font:create(name, size, weight, italic, quality)
	local pfont = ffi.new('struct sID3DXFont*[1]')
	C.D3DXCreateFontA(d3d9_device, size or 12, 0, weight or 400, 1, italic or false, quality or 0, 0, 0, 0, name or "Arial", pfont)
	table.insert(fonts, pfont)
	return pfont[0]
end

function dxut.texture:create_from_file(path)
	if not doesFileExist(path) then return nil end
	local ptexture = ffi.new('struct sIDirect3DTexture9*[1]')
	local file = io.open(path, "rb")
	local data = file:read("*a")
	file:close()
	if C.D3DXCreateTextureFromFileInMemory(d3d9_device, data, #data, ptexture) < 0 then return nil end
	table.insert(textures, ptexture)
	return ptexture[0]
end

function dxut.texture:create(width, height)
	local ptexture = ffi.new('struct sIDirect3DTexture9*[1]')
	if C.D3DXCreateTexture(d3d9_device, width, height, 1, 0, 21, 1, ptexture) < 0 then return nil end
	table.insert(textures, ptexture)
	return ptexture[0]
end

function dxut.render:draw_text(font, text, x, y, color, drop_shadow)
	local rect = ffi.new('long[4]', x + 1, y + 1, 0, 0)
	if drop_shadow then font:DrawTextA(nil, text, -1, rect, 0x0002, 0xFF000000) end
	rect[0], rect[1] = x, y
	font:DrawTextA(nil, text, -1, rect, 0x0002, color)
end

function dxut.render:draw_box(x, y, width, height, color)
	local vertexes = ffi.new('unsigned char[?]', VERTEX_NOTEXTURE_SIZE * 4)
	local pvertex = ffi.cast('void*', vertexes)
	local color = ffi.new('unsigned long[1]', color)
	local vertex = {
		{x, y + height, 0.0, color},
		{x, y, 0.0, color},
		{x + width, y + height, 0.0, color},
		{x + width, y, 0.0, color}
	}
	for i = 1, #vertex do
		ffi.copy(pvertex, vertex[i], VERTEX_NOTEXTURE_SIZE)
		pvertex = pvertex + VERTEX_NOTEXTURE_SIZE
	end
	d3d9_device:SetFVF(FVF_NOTEXTURE)
	d3d9_device:SetTexture(0, nil)
	d3d9_device:DrawPrimitiveUP(self.TRIANGLE_STRIP, 2, vertexes, VERTEX_NOTEXTURE_SIZE)
end

function dxut.render:draw_texture(texture, x, y, width, height, color)
	local vertexes = ffi.new('unsigned char[?]', VERTEX_TEXTURE_SIZE * 4)
	local pvertex = ffi.cast('void*', vertexes)
	local color = ffi.new('unsigned long[1]', color or 0xFFFFFFFF)
	local vertex = {
		{x, y + height, 0.0, color, 0.0, 1.0},
		{x, y, 0.0, color, 0.0, 0.0},
		{x + width, y + height, 0.0, color, 1.0, 1.0},
		{x + width, y, 0.0, color, 1.0, 0.0}
	}
	for i = 1, #vertex do
		ffi.copy(pvertex, vertex[i], VERTEX_TEXTURE_SIZE)
		pvertex = pvertex + VERTEX_TEXTURE_SIZE
	end
	d3d9_device:SetFVF(FVF_TEXTURE)
	d3d9_device:SetTexture(0, texture)
	d3d9_device:DrawPrimitiveUP(self.TRIANGLE_STRIP, 2, vertexes, VERTEX_TEXTURE_SIZE)
end

function dxut.render:draw_line(x1, y1, x2, y2, width, color)
	local vertexes = ffi.new('unsigned char[?]', VERTEX_NOTEXTURE_SIZE * 2)
	local pvertex = ffi.cast('void*', vertexes)
	local color = ffi.new('unsigned long[1]', color)
	local vertex = {
		{x1, y1, 0.0, color},
		{x2, y2, 0.0, color},
	}
	for i = 1, #vertex do
		ffi.copy(pvertex, vertex[i], VERTEX_NOTEXTURE_SIZE)
		pvertex = pvertex + VERTEX_NOTEXTURE_SIZE
	end
	d3d9_device:SetFVF(FVF_NOTEXTURE)
	d3d9_device:SetTexture(0, nil)
	d3d9_device:DrawPrimitiveUP(self.LINE_LIST, 1, vertexes, VERTEX_NOTEXTURE_SIZE)
end

function dxut.render:draw_circle(x, y, radius, color, width, is_filled)
	local vertexes = {}
	if is_filled then
		for i = 0, 360 do
			table.insert(vertexes, {x, y, 0.0, ffi.new('unsigned long[1]', color)})
			local rad = math.rad(i)
			table.insert(vertexes, {x + math.cos(rad) * radius, y - math.sin(rad) * radius, 0.0, ffi.new('unsigned long[1]', color)})
			rad = math.rad(i+1)
			table.insert(vertexes, {x + math.cos(rad) * radius, y - math.sin(rad) * radius, 0.0, ffi.new('unsigned long[1]', color)})
		end
		local p_vertex = ffi.new('unsigned char[?]', #vertexes * VERTEX_NOTEXTURE_SIZE)
		local pointer = ffi.cast('void*', p_vertex)
		for i = 1, #vertexes do
			ffi.copy(pointer, vertexes[i], VERTEX_NOTEXTURE_SIZE)
			pointer = pointer + VERTEX_NOTEXTURE_SIZE
		end
		d3d9_device:SetFVF(FVF_NOTEXTURE)
		d3d9_device:SetTexture(0, nil)
		d3d9_device:DrawPrimitiveUP(self.TRIANGLE_LIST, #vertexes / 3, p_vertex, VERTEX_NOTEXTURE_SIZE)
	else
		for i = 0, 360 do
			local rad = math.rad(i)
			table.insert(vertexes, {x + math.cos(rad) * radius, y - math.sin(rad) * radius, 0.0, ffi.new('unsigned long[1]', color)})
		end
		local p_vertex = ffi.new('unsigned char[?]', #vertexes * VERTEX_NOTEXTURE_SIZE)
		local pointer = ffi.cast('void*', p_vertex)
		for i = 1, #vertexes do
			ffi.copy(pointer, vertexes[i], VERTEX_NOTEXTURE_SIZE)
			pointer = pointer + VERTEX_NOTEXTURE_SIZE
		end
		d3d9_device:SetFVF(FVF_NOTEXTURE)
		d3d9_device:SetTexture(0, nil)
		d3d9_device:DrawPrimitiveUP(self.LINE_STRIP, #vertexes-1, p_vertex, VERTEX_NOTEXTURE_SIZE)
	end
end

-- Events
function onD3DPresent(device)
	callEvent(ev.RESET, device)
end

function onD3DLost(device)
	for k, v in ipairs(fonts) do
		v[0]:OnLostDevice()
	end
	callEvent(ev.LOST, device)
end

function onD3DReset(device)
	d3d9_device = device
	for k, v in ipairs(fonts) do
		v[0]:OnResetDevice()
	end
	callEvent(ev.RESET, device)
end

function onExit()
	for k, v in ipairs(fonts) do
		v[0]:Release()
	end
	for k, v in ipairs(textures) do
		v[0]:Release()
	end
	callEvent(ev.RELEASE)
end

return dxut