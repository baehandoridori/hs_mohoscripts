-- **************************************************
-- BHS_SYN_CHset
-- Previews HS_CharacterSetting thumbnails without rendering/camera work.
-- Copies preview images from the shared "캐릭터 세팅" folder into
-- ScriptResources/BHS_SYN_CHset using ASCII-safe filenames and shows them.
-- **************************************************

ScriptName = "BHS_SYN_CHset"
BHS_SYN_CHset = {}

local MSG_BASE = (LM and LM.GUI and LM.GUI.MSG_BASE) or (MOHO and MOHO.MSG_BASE) or -5000

-- HS 캐릭터 세팅 루트 (원본과 동일 경로 사용)
local DEFAULT_CHAR_DIR = [[G:\공유 드라이브\사우스 코리안 파크\[]사코팍 캐릭터 세팅]]

local RESOURCE_DIR_NAME = "BHS_SYN_CHset"
local RESOURCE_REL_DIR = "ScriptResources/" .. RESOURCE_DIR_NAME

-- ---------------------------------------------------
-- Utils
-- ---------------------------------------------------
local function LOG(str)
	print(">>> [BHS_CHSET] " .. tostring(str))
end

local function detectOS()
	local osEnv = os.getenv("OS")
	if osEnv and string.lower(string.sub(osEnv, 1, 3)) == "win" then
		return "win"
	end
	return "unix"
end

local function toWin(path)
	return string.gsub(path or "", "/", "\\")
end

local function toUnix(path)
	return string.gsub(path or "", "\\", "/")
end

local function ensureTrailingBackslash(path)
	if string.sub(path, -1) ~= "\\" then
		return path .. "\\"
	end
	return path
end

local function ensureDir(path)
	if detectOS() == "win" then
		os.execute(string.format('cmd /c mkdir "%s"', toWin(path)))
	else
		os.execute(string.format('mkdir -p "%s"', toUnix(path)))
	end
end

local function joinWin(dir, name)
	if not dir or dir == "" then return name end
	local base = toWin(dir)
	if string.sub(base, -1) ~= "\\" then base = base .. "\\" end
	return base .. name
end

local function fileExists(path)
	local f = io.open(path, "rb")
	if f then f:close() return true end
	return false
end

local function copyBinary(src, dest)
	local fsrc = io.open(src, "rb")
	if not fsrc then return false, "open src" end
	local data = fsrc:read("*all")
	fsrc:close()

	ensureDir(string.match(dest, "^(.*)[/\\][^/\\]+$") or ".")

	local fdst = io.open(dest, "wb")
	if not fdst then return false, "open dest" end
	fdst:write(data)
	fdst:close()
	return true
end

local function getExt(path)
	return string.lower(string.match(path, "%.([^%.]+)$") or "")
end

local function stripExt(path)
	if not path then return path end
	return string.match(path, "^(.*)%.[^%.]+$") or path
end

local function existsInDir(moho, dirAbs, filename)
	local searchRoot = detectOS() == "win" and ensureTrailingBackslash(toWin(dirAbs)) or toUnix(dirAbs .. "/")
	local ok = pcall(function() moho:BeginFileListing(searchRoot) end)
	if not ok then return false end
	local item = moho:GetNextFile()
	while item do
		if string.lower(item) == string.lower(filename) then
			return true
		end
		item = moho:GetNextFile()
	end
	return false
end

local function normalizeKey(str)
	if not str then return "" end
	local lowered = string.lower(str)
	local ascii = string.gsub(lowered, "[^%w]+", "_")
	ascii = string.gsub(ascii, "_+", "_")
	ascii = string.gsub(ascii, "^_+", "")
	ascii = string.gsub(ascii, "_+$", "")
	if ascii == "" then ascii = "item" end
	return ascii
end

local function shortHash(str)
	local h = 5381
	for i = 1, #str do
		h = ((h * 33 + string.byte(str, i)) % 4294967295)
	end
	return string.format("%08x", h)
end

local function makeSafeBase(name, fileName, folderPath)
	local key = normalizeKey(name)
	local hash = shortHash((folderPath or "") .. "|" .. (name or ""))
	return key .. "_" .. hash
end

local function logImageLoad(path)
	local ok = false
	if LM and LM.Image then
		local img = LM.Image:new_local()
		ok = img:Init(toUnix(path))
		img = nil
	end
	LOG("ImageLoadTest path=" .. tostring(path) .. " ok=" .. tostring(ok))
end

local function canInitImage(path)
	if not path or not LM or not LM.Image then return nil end
	local candidates = { path }
	if getExt(path) == "" then
		table.insert(candidates, path .. ".png")
	end
	for _, p in ipairs(candidates) do
		local img = LM.Image:new_local()
		local ok = img:Init(toUnix(p))
		img = nil
		if ok then return p end
	end
	return nil
end

local function findExistingResource(moho, resourceDirAbs, folderName)
	local safeBase = makeSafeBase(folderName, "", "") -- fileName 제외, 폴더/이름 기반
	local searchRoot = detectOS() == "win" and ensureTrailingBackslash(toWin(resourceDirAbs)) or toUnix(resourceDirAbs .. "/")
	local found = nil
	local ok = pcall(function() moho:BeginFileListing(searchRoot) end)
	if not ok then return nil end
	local item = moho:GetNextFile()
	while item do
		-- safeBase로 시작하는 파일을 찾으면 사용
		if string.match(string.lower(item), "^" .. string.lower(safeBase) .. "%.") then
			local rel = toUnix(RESOURCE_REL_DIR .. "/" .. item)
			found = stripExt(rel)
			break
		end
		item = moho:GetNextFile()
	end
	return found
end

local function ensureResourceDir(moho)
	local osType = detectOS()
	local absPath = moho:UserAppDir() .. "/scripts/" .. RESOURCE_REL_DIR
	local absUnix = toUnix(absPath)
	if osType == "win" then
		local target = toWin(absPath)
		local cmd = string.format("powershell -ExecutionPolicy Bypass -Command \"New-Item -ItemType Directory -Force -LiteralPath '%s'\"", target)
		os.execute(cmd)
		return absUnix
	else
		os.execute(string.format("mkdir -p \"%s\"", absUnix))
		return absUnix
	end
end

local function listCharFolders(moho, rootPath)
	local folders = {}
	local searchRoot = ensureTrailingBackslash(toWin(rootPath))
	pcall(function() moho:BeginFileListing(searchRoot) end)
	local item = moho:GetNextFile()
	while item do
		if string.sub(item, 1, 1) ~= "." and not string.find(item, "%[") and not string.find(item, "%]") then
			if string.find(item, "캐릭터") then
				table.insert(folders, { name = item, path = searchRoot .. item })
			end
		end
		item = moho:GetNextFile()
	end
	table.sort(folders, function(a, b) return a.name < b.name end)
	return folders
end

local function findPreviewForFolder(moho, folderPath, folderName)
	local previewDir = ensureTrailingBackslash(joinWin(folderPath, "preview"))
	local lowerFolder = string.lower(folderName or "")
	local targets = {
		lowerFolder .. "_preview.png",
		lowerFolder .. "_preview.jpg",
		lowerFolder .. "_preview.jpeg",
		lowerFolder .. ".png",
		lowerFolder .. ".jpg",
		lowerFolder .. ".jpeg",
	}

	local best, fallback = nil, nil
	pcall(function() moho:BeginFileListing(previewDir) end)
	local item = moho:GetNextFile()
	while item do
		local lowerItem = string.lower(item)
		if lowerItem:match("%.png$") or lowerItem:match("%.jpe?g$") then
			if not fallback then fallback = item end
			for _, t in ipairs(targets) do
				if lowerItem == t then
					best = item
					break
				end
			end
		end
		if best then break end
		item = moho:GetNextFile()
	end

	local chosen = best or fallback
	if not chosen then return nil, nil end

	local fullPath = joinWin(previewDir, chosen)
	return fullPath, getExt(chosen)
end

local function copyToResource(moho, sourcePath, folderName, fileExt, resourceDirAbs, folderPath)
	if not fileExt or fileExt == "" then return nil end

	local safeBase = makeSafeBase(folderName, "", folderPath)
	local relWithExt = toUnix(RESOURCE_REL_DIR .. "/" .. safeBase .. "." .. fileExt)
	local relNoExt = stripExt(relWithExt)
	local targetRaw = resourceDirAbs .. "/" .. safeBase .. "." .. fileExt
	local targetAbs = detectOS() == "win" and toWin(targetRaw) or toUnix(targetRaw)
	LOG("Copy try: src=" .. tostring(sourcePath) .. " -> dest=" .. tostring(targetAbs))

	if existsInDir(moho, resourceDirAbs, safeBase .. "." .. fileExt) then
		LOG("Already exists, skip copy: " .. tostring(targetAbs))
		logImageLoad(relNoExt)
		return relNoExt
	end

	local osType = detectOS()
	if osType == "win" then
		local src = toWin(sourcePath)
		local destDir = ensureTrailingBackslash(toWin(resourceDirAbs))
		local dest = targetAbs
		local tmp = (os.getenv("TEMP") or "C:\\Windows\\Temp") .. "\\bhs_copy.ps1"
		local f = io.open(tmp, "wb")
		if f then
			f:write(string.char(0xEF, 0xBB, 0xBF))
			f:write(string.format("New-Item -ItemType Directory -Force -LiteralPath '%s'\r\n", destDir))
			f:write(string.format("Copy-Item -LiteralPath '%s' -Destination '%s' -Force\r\n", src, dest))
			f:close()
			os.execute(string.format("powershell -ExecutionPolicy Bypass -File \"%s\"", tmp))
			--os.remove(tmp) -- 남겨두어도 무방
		else
			LOG("Copy script create failed: " .. tostring(tmp))
		end
		if not fileExists(dest) then
			local srcDir = string.match(src, "^(.*)[/\\][^/\\]+$") or src
			local fileName = string.match(src, "[^/\\]+$") or ""
			local roboCmd = string.format('robocopy "%s" "%s" "%s" /NFL /NDL /NJH /NJS /NC /NS /NP /R:1 /W:1 >nul', srcDir, destDir, fileName)
			os.execute(roboCmd)
		end
	else
		local destDir = toUnix(resourceDirAbs)
		local src = toUnix(sourcePath)
		local dest = toUnix(targetAbs)
		os.execute(string.format("mkdir -p \"%s\" && cp \"%s\" \"%s\"", destDir, src, dest))
	end

	if existsInDir(moho, resourceDirAbs, safeBase .. "." .. fileExt) then
		logImageLoad(relNoExt)
		return relNoExt
	end
	-- PowerShell/CP가 실패한 경우 바이너리 직접 복사 시도
	local ok, reason = copyBinary(sourcePath, targetAbs)
	if ok and existsInDir(moho, resourceDirAbs, safeBase .. "." .. fileExt) then
		LOG("Fallback copy succeeded: " .. tostring(targetAbs))
		logImageLoad(relNoExt)
		return relNoExt
	end

	LOG("Copy failed: " .. tostring(sourcePath) .. " -> " .. tostring(targetAbs) .. " reason=" .. tostring(reason))
	return nil
end

local function buildIconEntries(moho)
	local entries = {}
	local resourceDirAbs = ensureResourceDir(moho)

	local folders = listCharFolders(moho, DEFAULT_CHAR_DIR)
	for _, folder in ipairs(folders) do
		local existingRel = findExistingResource(moho, resourceDirAbs, folder.name)
		if existingRel then
			local relNoExt = stripExt(existingRel)
			LOG("Cache hit: " .. folder.name .. " -> " .. relNoExt)
			logImageLoad(relNoExt)
			table.insert(entries, {
				displayName = folder.name,
				relPath = relNoExt,
				source = "cache"
			})
		else
			local previewPath, ext = findPreviewForFolder(moho, folder.path, folder.name)
			if previewPath and ext ~= "" then
				local rel = copyToResource(moho, previewPath, folder.name, ext, resourceDirAbs, folder.path)
				local relNoExt = rel and stripExt(rel) or nil
				if relNoExt then logImageLoad(relNoExt) end
				table.insert(entries, {
					displayName = folder.name,
					relPath = relNoExt,
					source = previewPath
				})
			else
				table.insert(entries, {
					displayName = folder.name,
					relPath = nil,
					source = nil
				})
			end
		end
	end

	return entries
end

-- ---------------------------------------------------
-- Dialog
-- ---------------------------------------------------
local BHS_CH_Dialog = {}

function BHS_CH_Dialog:new(moho, entries)
	local d = LM.GUI.SimpleDialog("BHS 캐릭터 프리뷰", BHS_CH_Dialog)
	d.moho = moho
	d.entries = entries or {}
	d.selected = nil
	d.msgOffset = MSG_BASE + 300

	local l = d:GetLayout()

	l:AddChild(LM.GUI.StaticText("HS_캐릭터세팅 프리뷰 (ScriptResources/" .. RESOURCE_DIR_NAME .. ")"), LM.GUI.ALIGN_LEFT)
	l:AddPadding(6)

	if #d.entries == 0 then
		l:AddChild(LM.GUI.StaticText("프리뷰를 찾을 수 없습니다."), LM.GUI.ALIGN_LEFT)
		return d
	end

	local cols = 8
	local col = 0
	l:PushV()
	l:PushH()
	for idx, entry in ipairs(d.entries) do
		local msgID = d.msgOffset + idx
		local btn
		-- 예제 스크립트 방식: 검증 없이 확장자 없는 경로를 바로 전달
		if entry.relPath then
			btn = LM.GUI.ImageButton(entry.relPath, entry.displayName, false, msgID)
		else
			btn = LM.GUI.Button(entry.displayName, msgID)
		end
		btn:SetToolTip(entry.displayName)
		l:AddChild(btn, LM.GUI.ALIGN_LEFT)

		col = col + 1
		if col >= cols then
			col = 0
			l:Pop()
			l:PushH()
		end
	end
	l:Pop() -- final row
	l:Pop()

	l:AddPadding(6)
	l:AddChild(LM.GUI.StaticText("선택 상태:"), LM.GUI.ALIGN_LEFT)
	d.status = LM.GUI.TextControl(320, "[선택 없음]", 0, LM.GUI.FIELD_TEXT, "")
	d.status:Enable(false)
	l:AddChild(d.status, LM.GUI.ALIGN_FILL)

	return d
end

function BHS_CH_Dialog:HandleMessage(msg)
	local idx = msg - self.msgOffset
	if idx >= 1 and self.entries[idx] then
		self.selected = self.entries[idx]
		local label = self.selected.displayName
		if self.selected.source then
			label = label .. " (" .. self.selected.source .. ")"
		end
		LOG("Button click: " .. label .. " rel=" .. tostring(self.selected.relPath))
		self.status:SetValue(label)
		self.status:Redraw()
	end
end

-- ---------------------------------------------------
-- Script API
-- ---------------------------------------------------
function BHS_SYN_CHset:Name() return "BHS_SYN_CHset" end
function BHS_SYN_CHset:Version() return "1.0" end
function BHS_SYN_CHset:Description() return "HS 캐릭터 세팅 프리뷰를 아스키 캐시로 복사 후 아이콘으로 표시" end
function BHS_SYN_CHset:Creator() return "Moho Assistant" end
function BHS_SYN_CHset:UILabel() return "BHS_SYN_CHset" end

function BHS_SYN_CHset:Run(moho)
	LOG("Start cache & preview build")
	local entries = buildIconEntries(moho)
	LOG("Entries: " .. tostring(#entries))

	local dlg = BHS_CH_Dialog:new(moho, entries)
	dlg:DoModal()
end
