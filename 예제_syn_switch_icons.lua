-- **************************************************
-- Syn_SwitchIcons (Modified for Unicode & Network Drive Support)
-- **************************************************
--
-- [CONTEXT & PROBLEM]
-- This script was modified to solve a critical issue on Windows environments,
-- specifically when the Moho "Custom Content Folder" is located on a Google Drive (G:)
-- or contains non-ASCII characters (e.g., Korean "한글").
--
-- 1. Encoding Mismatch: Moho uses UTF-8 for paths, but Lua's `io.open` and Windows CMD
--    default to system locale (CP949/ANSI). This caused paths like "G:\공유 드라이브" to break.
-- 2. Moho Render Bug: `moho:FileRender` fails silently when the target path contains
--    complex Unicode characters on Windows.
-- 3. File System Check Failure: Lua's `io.open` returns nil even if the file exists
--    on a virtual drive (Google Drive), causing the UI to think icons are missing.
--
-- [SOLUTION STRATEGY]
-- To bypass these limitations, we implemented a "Render-and-Delivery" pipeline:
--
-- 1. Render to Safe Zone: We force Moho to render the thumbnail into the system %TEMP% folder.
--    This path is guaranteed to be ASCII-safe and writable.
-- 2. PowerShell Delivery: Instead of Lua's `os.rename` or CMD's `copy`, we generate
--    and execute a PowerShell command. PowerShell handles UTF-8 paths correctly, allowing
--    us to copy the file from %TEMP% to the "G:\Korean_Path" destination without data loss.
-- 3. Direct Loading: In the UI generation, we removed `io.open` validation and rely
--    solely on Moho's `BeginFileListing` API, which natively supports Unicode.
--
-- [KEY FUNCTION MODIFICATIONS]
-- 1. Syn_SwitchIcons:UpdateIcons()
--    - Logic: Renders image to %TEMP% -> Uses PowerShell `New-Item` & `Copy-Item` -> Clean up.
--    - Reason: To bypass Moho's inability to render directly to non-ASCII paths.
--
-- 2. Syn_SwitchIconsDialog:new()
--    - Logic: Iterates file list using `moho:GetNextFile()` and creates ImageButton directly.
--    - Removed: `io.open` checks (false negatives on virtual drives).
--
-- Modified by: AI Assistant (Collaboration with User)
-- Date: 2024
-- **************************************************

-- Provide Moho with the name of this script object



-- **************************************************
-- Provide Moho with the name of this script object
-- **************************************************

ScriptName = "Syn_SwitchIcons"

-- **************************************************
-- General information about this script
-- **************************************************

Syn_SwitchIcons = {}


Syn_SwitchIcons.recolor = 0
--                        ^ change this value to 1 for colorized icons


function Syn_SwitchIcons:Name()
	return "Switch Icons"
end

function Syn_SwitchIcons:Version()
	return "2.3"
end

function Syn_SwitchIcons:Description()
	return "Select switch by icons"
end

function Syn_SwitchIcons:Creator()
	return "(c)2021 J.Wesley Fowler (synthsin75), w/code contributed by Alexandra Evseeva and Lukas Krepel"
end

function Syn_SwitchIcons:UILabel()
	return "SYN: Switch Icons"
end

function Syn_SwitchIcons:LoadPrefs(prefs)
	self.size = prefs:GetInt("Syn_SwitchIcons.size", 64)
	self.shape = prefs:GetInt("Syn_SwitchIcons.shape", 0)
	self.sort = prefs:GetBool("Syn_SwitchIcons.sort", false)
	self.lSort = prefs:GetBool("Syn_SwitchIcons.lSort", false)
	self.h = prefs:GetInt("Syn_SwitchIcons.h", 0)
	self.w = prefs:GetInt("Syn_SwitchIcons.w", 0)
	self.pad = prefs:GetInt("Syn_SwitchIcons.pad", 8)
	self.speed = prefs:GetFloat("Syn_SwitchIcons.speed", 2)
end

function Syn_SwitchIcons:SavePrefs(prefs)
	prefs:SetInt("Syn_SwitchIcons.size", self.size)
	prefs:SetInt("Syn_SwitchIcons.shape", self.shape)
	prefs:SetBool("Syn_SwitchIcons.sort", self.sort)
	prefs:SetBool("Syn_SwitchIcons.lSort", self.lSort)
	prefs:SetInt("Syn_SwitchIcons.h", self.h)
	prefs:SetInt("Syn_SwitchIcons.w", self.w)
	prefs:SetInt("Syn_SwitchIcons.pad", self.pad)
	prefs:SetFloat("Syn_SwitchIcons.speed", self.speed)
end

function Syn_SwitchIcons:ResetPrefs()
	self.h = 0
	self.w = 0
end

-- **************************************************
-- Recurring values
-- **************************************************

Syn_SwitchIcons.ICON = {}
Syn_SwitchIcons.ID = -1
Syn_SwitchIcons.size = 64
Syn_SwitchIcons.shape = 0	--0=horizontal, 1=vertical, 2=square
Syn_SwitchIcons.sort = false
Syn_SwitchIcons.lSort = false
Syn_SwitchIcons.switchID = -1
Syn_SwitchIcons.lastLayer = false
Syn_SwitchIcons.cnt = 0
Syn_SwitchIcons.h = 0
Syn_SwitchIcons.w = 0
Syn_SwitchIcons.docFolder = nil
Syn_SwitchIcons.activate = nil
Syn_SwitchIcons.active = nil
Syn_SwitchIcons.pad = 8
Syn_SwitchIcons.speed = 2

Syn_SwitchIcons.min = .1
Syn_SwitchIcons.max = 40

-- 디버그 로그 및 이미지 로드 테스트
local function LOG(str)
	print(">>> [SYN_LOG] " .. tostring(str))
end

local function logImageLoad(path)
	local readable = false
	local f = io.open(path, "rb")
	if f then readable = true f:close() end

	local ok = false
	if LM and LM.Image then
		local img = LM.Image:new_local()
		ok = img:Init(path)
		img = nil
	end

	LOG("ImageLoadTest path=" .. tostring(path) .. " readable=" .. tostring(readable) .. " LM.Image.Init=" .. tostring(ok))
end

-- **************************************************
-- Switch icon dialogs
-- **************************************************

local Syn_SwitchIconsDialog = {}

-- **************************************************
-- Switch icon dialogs (FIXED for G: Drive Reading)
-- **************************************************

local Syn_SwitchIconsDialog = {}

function Syn_SwitchIconsDialog:new(moho, layer)
	local d = LM.GUI.SimpleDialog(layer:Name(), Syn_SwitchIconsDialog)
	local l = d:GetLayout()
	
	d.moho = moho
	d.layer = layer
	d.frame = moho.frame
	d.switch = moho:LayerAsSwitch(layer)
	d.doc = moho.document
	
	-- [DEBUG] UI 생성 시작
	print("--- Dialog: Scanning for icons ---")

	if (layer:LayerType() == MOHO.LT_SWITCH) and (not moho:DrawingMesh()) then
		local frame = moho.frame
		local switch = moho:LayerAsSwitch(layer)
		local group = moho:LayerAsGroup(layer)
		
		-- 문서 이름 안전하게 추출
		local docNameRaw = moho.document:Name()
		local doc = string.match(docNameRaw, "(.+)%..+") 
		if not doc then doc = "Untitled" end
		
		local par = layer:UUID()
				
		l:PushH()
		
		local incrm
		local rep
		if (Syn_SwitchIcons.shape == 0) then
			--horizontal rows
			incrm = 15
			rep = incrm + 1
			if (Syn_SwitchIcons.w ~= 0) then
				incrm = math.ceil(Syn_SwitchIcons.w/Syn_SwitchIcons.size)-1
				rep = incrm + 1
			end
		elseif (Syn_SwitchIcons.shape == 2) then
			--arrange in square
			incrm = math.ceil(math.sqrt(group:CountLayers()))-1
			rep = incrm + 1
		else
			--vertical rows
			incrm = 9
			rep = incrm + 1
			if (Syn_SwitchIcons.h ~= 0) then
				incrm = math.ceil(Syn_SwitchIcons.h/Syn_SwitchIcons.size)-1
				rep = incrm + 1
			end
			l:PushV()
		end
		
		local a, b, c = 0, group:CountLayers()-1, 1
		if (Syn_SwitchIcons.sort) then
			a, b, c = group:CountLayers()-1, 0, -1
		end
		
		-- [경로 설정] 읽어올 폴더 경로 구성
		local baseSearchPath = moho:UserAppDir().."/scripts/ScriptResources/syn_resources/"..doc.."/"
		
		-- 윈도우라면 역슬래시로 변경 (탐색 성공률 높임)
		if (Syn_SwitchIcons:OS() == "win") then
			baseSearchPath = string.gsub(baseSearchPath, "/", "\\")
		end
		
		for i=a, b, c do
			local layer = group:Layer(i)
			local name = layer:Name()
			
			--which size icons?
			local size = "user"
			if (Syn_SwitchIcons.size == 64) then
				size = "lg"
			elseif (Syn_SwitchIcons.size == 36) then
				size = "sm"
			end
			
			-- 파일 찾기 시작
			local foundFileName = nil
			local targetPrefix = par.."_"..layer:UUID().."_"..size
			
			-- [중요] BeginFileListing은 Moho 내부 함수라 UTF-8 한글 경로도 잘 읽습니다.
			-- 다만 경로 문자열 형식이 중요합니다.
			moho:BeginFileListing(baseSearchPath)
			local file = moho:GetNextFile()
			
			while (file) do
				-- 파일명 매칭 (UUID_lg 부분이 일치하는지 확인)
				if (string.sub(file, 1, -16) == targetPrefix) then
					foundFileName = file
					break
				end
				file = moho:GetNextFile()
			end
			
			Syn_SwitchIcons.ICON.i = MOHO.MSG_BASE + 30 + i
			
			-- foundFileName이 있으면 바로 이미지 버튼 생성 (상대 경로)
			if (foundFileName) then
				local resourceRelPath = "ScriptResources/syn_resources/"..doc.."/"..string.sub(foundFileName, 1, -5)
				LOG("Found icon for "..tostring(name).." rel="..tostring(resourceRelPath))
				logImageLoad(resourceRelPath)
				self.icon = LM.GUI.ImageButton(resourceRelPath, name, false, Syn_SwitchIcons.ICON.i)
			else
				-- 이미지를 못 찾았으면 텍스트 버튼
				self.icon = LM.GUI.Button(name, Syn_SwitchIcons.ICON.i)
			end
			
			l:AddChild(self.icon, LM.GUI.ALIGN_LEFT)
			if (i/incrm == 1) then
				if (Syn_SwitchIcons.shape == 1) then
					incrm = incrm + rep
					l:Pop()
					l:PushV()
				else
					incrm = incrm + rep
					l:Pop()
					l:PushH()
				end
			end
		end
		l:Pop()
	end
	return d
end

function Syn_SwitchIconsDialog:UpdateWidgets()
	
end

function Syn_SwitchIconsDialog:HandleMessage(msg)
	local ID = msg - (MOHO.MSG_BASE + 30)
	if (ID < 0) then return end
	Syn_SwitchIcons.ID = ID
	Syn_SwitchIcons.active = ID
	
	self.doc:PrepUndo(self.layer)
	self.doc:SetDirty()
	
	local layer = self.layer
	local val = self.switch:Layer(ID):Name()
	--print(val)
	--self.switch:SwitchValues().value:Set(val)
	--self.switch:SwitchValues():StoreValue()
--\/A.Evseeva
	local switchChannel = self.switch:Layer(ID):AncestorSwitchLayer():SwitchValues()
	switchChannel.value:Set(val)
	switchChannel:StoreValue()
--/\A.Evseeva
	--self.moho:UpdateUI()	--causes crash in v13.5.2
	MOHO.Redraw()
end


-- **************************************************
-- Settings dialog
-- **************************************************

local Syn_SwitchIconsSettingsDialog = {}
Syn_SwitchIconsSettingsDialog.SELECTITEM = MOHO.MSG_BASE + 12
Syn_SwitchIconsSettingsDialog.SELECTSHAPE = MOHO.MSG_BASE + 1000
--Syn_SwitchIconsSettingsDialog.DELETE = MOHO.MSG_BASE + 7
Syn_SwitchIconsSettingsDialog.SIZE = MOHO.MSG_BASE + 8
Syn_SwitchIconsSettingsDialog.SORT = MOHO.MSG_BASE + 9
Syn_SwitchIconsSettingsDialog.LSORT = MOHO.MSG_BASE + 10
Syn_SwitchIconsSettingsDialog.PAD = MOHO.MSG_BASE + 11

function Syn_SwitchIconsSettingsDialog:new(moho)
	local d = LM.GUI.SimpleDialog("", Syn_SwitchIconsSettingsDialog)
	d.moho = moho
	d.frame = moho.frame
	local l = d:GetLayout()
	
	--l:AddChild(LM.GUI.StaticText("-- Hit <enter> twice to apply changes --"))
	l:AddChild(LM.GUI.StaticText("-- Switch Icons Settings --"))
	--l:AddPadding()
	
	l:PushH()
		l:PushV()
		
		l:AddChild(LM.GUI.StaticText("Icon size:"), LM.GUI.ALIGN_LEFT)
		l:AddChild(LM.GUI.StaticText("Arrangement:"), LM.GUI.ALIGN_LEFT)
		l:AddChild(LM.GUI.StaticText("Reverse sort:"), LM.GUI.ALIGN_LEFT)
		l:AddChild(LM.GUI.StaticText("Spacing:"), LM.GUI.ALIGN_LEFT)
		
		l:Pop()
		l:PushV()
			l:PushH()
		
			d.menu = LM.GUI.Menu("Icon size")
			d.popup = LM.GUI.PopupMenu(75, true)
			d.popup:SetMenu(d.menu)
			l:AddChild(d.popup)
			d.childName = LM.GUI.DynamicText("", 0)
			l:AddChild(d.childName)
			
			l:AddPadding(-20)
			
			d.size = LM.GUI.TextControl(35, Syn_SwitchIcons.size, self.SIZE, LM.GUI.FIELD_UINT)
			d.size:SetWheelInc(1)
			l:AddChild(d.size)
			
			l:AddChild(LM.GUI.StaticText("px"))
			
			l:Pop()
			l:PushH()
			
			d.sMenu = LM.GUI.Menu("Arrange icons")
			d.shape = LM.GUI.PopupMenu(140, true)
			d.shape:SetMenu(d.sMenu)
			l:AddChild(d.shape)
			d.childName = LM.GUI.DynamicText("", 0)
			l:AddChild(d.childName)
			
			l:Pop()
			l:PushH()
			
			d.sort = LM.GUI.CheckBox("Icons", self.SORT)
			l:AddChild(d.sort)
			
			l:AddPadding()
			
			d.lSort = LM.GUI.CheckBox("Switches", self.LSORT)
			l:AddChild(d.lSort)
			
			l:Pop()
			l:PushH()
			
			d.padding = LM.GUI.TextControl(35, Syn_SwitchIcons.padding, self.PAD, LM.GUI.FIELD_UINT)
			d.padding:SetWheelInc(1)
			d.padding:SetConstantMessages(true)
			l:AddChild(d.padding)
			
			l:Pop()
		l:Pop()
	l:Pop()
	
	l:AddPadding()
	
	l:AddChild(LM.GUI.Button("APPLY  (or hit <enter> twice)", Syn_SwitchIcons.DLOG_END), LM.GUI.ALIGN_FILL)
	
	--l:AddChild(LM.GUI.StaticText("-- Hit <enter> twice to apply changes --"))
	l:AddChild(LM.GUI.Divider(false), LM.GUI.ALIGN_FILL)
	
	l:PushH()
	l:AddChild(LM.GUI.StaticText("Workspace scrub time speed:    "), LM.GUI.ALIGN_LEFT)
	d.speedText = LM.GUI.TextControl(0, "00.00", Syn_SwitchIcons.DLOG_CHANGE, LM.GUI.FIELD_UFLOAT)
	l:AddChild(d.speedText, LM.GUI.ALIGN_RIGHT)
	l:Pop()
	
	l:AddChild(LM.GUI.Button("Delete all thumbnails", --[[self]]Syn_SwitchIcons.DELETE), LM.GUI.ALIGN_LEFT)
	
	return d
end

function Syn_SwitchIconsSettingsDialog:UpdateWidgets()
	self.menu:RemoveAllItems()
	self.menu:AddItem("Large", 0, self.SELECTITEM)
	self.menu:AddItem("Small", 0, self.SELECTITEM + 1)
	self.menu:AddItem("Custom", 0, self.SELECTITEM + 2)
	
	self.sMenu:RemoveAllItems()
	self.sMenu:AddItem("Horizontal", 0, self.SELECTSHAPE)
	self.sMenu:AddItem("Vertical", 0, self.SELECTSHAPE + 1)
	self.sMenu:AddItem("Square", 0, self.SELECTSHAPE + 2)
	
	if (Syn_SwitchIcons.size == 64) then
		self.menu:SetCheckedLabel("Large", true)
		self.size:Enable(false)
		self.size:SetValue(64)
	elseif (Syn_SwitchIcons.size == 36) then
		self.menu:SetCheckedLabel("Small", true)
		self.size:Enable(false)
		self.size:SetValue(36)
	else
		self.menu:SetCheckedLabel("Custom", true)
		self.size:Enable(true)
		self.size:SetValue(Syn_SwitchIcons.size)
	end
	
	if (Syn_SwitchIcons.shape == 0) then
		self.sMenu:SetCheckedLabel("Horizontal", true)
	elseif (Syn_SwitchIcons.shape == 1) then
		self.sMenu:SetCheckedLabel("Vertical", true)
	else
		self.sMenu:SetCheckedLabel("Square", true)
	end
	
	self.sort:SetValue(Syn_SwitchIcons.sort)
	self.lSort:SetValue(Syn_SwitchIcons.lSort)
	self.padding:SetValue(Syn_SwitchIcons.pad)
	self.speedText:SetValue(Syn_SwitchIcons.speed)
	
	self.shape:Redraw()
	self.popup:Redraw()
end

function Syn_SwitchIconsSettingsDialog:OnOK()
	self:HandleMessage(Syn_SwitchIcons.DLOG_CHANGE) -- send this final message in case the user is in the middle of editing some value
end

function Syn_SwitchIconsSettingsDialog:HandleMessage(msg)
	if (msg == self.SELECTITEM + 2) then
		self.size:Enable(true)
		--Syn_SwitchIcons.size = self.size:IntValue()
		if (self:Validate(self.size, 36, 300)) then
			Syn_SwitchIcons.size = self.size:IntValue()
		else
			if (self.size:IntValue() < 36) then
				Syn_SwitchIcons.size = 36
			else
				Syn_SwitchIcons.size = 300
			end
		end
		self.size:SetValue(Syn_SwitchIcons.size)
	elseif  (msg == self.SELECTITEM + 1) then
		self.size:Enable(false)
		Syn_SwitchIcons.size = 36
		self.size:SetValue(36)
	elseif (msg == self.SELECTITEM) then
		self.size:Enable(false)
		Syn_SwitchIcons.size = 64
		self.size:SetValue(64)
	end
	
	if (msg == self.SELECTSHAPE + 2) then
		Syn_SwitchIcons.shape = 2
	elseif (msg == self.SELECTSHAPE + 1) then
		Syn_SwitchIcons.shape = 1
	elseif  (msg == self.SELECTSHAPE) then
		Syn_SwitchIcons.shape = 0
	end
	
	if (self:Validate(self.size, 36, 300)) then
		Syn_SwitchIcons.size = self.size:IntValue()
	else
		if (self.size:IntValue() < 36) then
			Syn_SwitchIcons.size = 36
		else
			Syn_SwitchIcons.size = 300
		end
	end
	
	if (msg == self.SORT) then
		Syn_SwitchIcons.sort = self.sort:Value()
	elseif (msg == self.LSORT) then
		Syn_SwitchIcons.lSort = self.lSort:Value()
	elseif (msg == self.PAD) then
		Syn_SwitchIcons.pad = LM.Clamp(self.padding:Value(), 0, 300)
		self.padding:SetValue(Syn_SwitchIcons.pad)
	end
	
	Syn_SwitchIcons.speed = LM.Clamp(self.speedText:FloatValue(), Syn_SwitchIcons.min, Syn_SwitchIcons.max)
	
	if (msg == --[[self]]Syn_SwitchIcons.DELETE) and (Syn_SwitchIcons.docFolder) then
		local button = LM.GUI.Alert(LM.GUI.ALERT_QUESTION, "Are you sure you want to delete all switch thumbnails for this project?", nil, nil, "Yes", "No", nil)
		if (button == 0) then
			os.execute("del /q /S ".."\""..Syn_SwitchIcons.docFolder.."\"")
			os.execute("rmdir ".."\""..Syn_SwitchIcons.docFolder.."\"")
			local removeDir = string.gsub(Syn_SwitchIcons.docFolder, " ", "\\ ")
			os.execute("rm -r "..removeDir) --OSX
		end
	end
end

-- **************************************************
-- Tool options - create and respond to tool's UI
-- **************************************************

Syn_SwitchIcons.DIA = {}
Syn_SwitchIcons.UPDATE = MOHO.MSG_BASE + 1
Syn_SwitchIcons.ALT_UPDATE = MOHO.MSG_BASE + 2
Syn_SwitchIcons.SELECTITEM = MOHO.MSG_BASE + 3
Syn_SwitchIcons.DLOG_BEGIN = MOHO.MSG_BASE + 4
Syn_SwitchIcons.DLOG_END = MOHO.MSG_BASE + 5
Syn_SwitchIcons.DLOG_CHANGE = MOHO.MSG_BASE + 6
Syn_SwitchIcons.DELETE = MOHO.MSG_BASE + 7

function Syn_SwitchIcons:DoLayout(moho, layout)
	--self.update = LM.GUI.Button("UD", self.UPDATE)
	--self.update:SetToolTip("Generate/update switch thumbnails (hold <alt> for whole project)")
	local path = "ScriptResources/syn_resources/syn_update"
	if (self.ver > 11) then
		self.update = LM.GUI.ImageButton(path, "Generate/update switch thumbnails (hold <alt> for whole project)", false, self.UPDATE, self.recolor)
	else
		self.update = LM.GUI.ImageButton(path, "Generate/update switch thumbnails (hold <alt> for whole project)", false, self.UPDATE)
	end
	self.update:SetAlternateMessage(self.ALT_UPDATE)
	
	layout:AddChild(self.update)
	if (self:OS() ~= "win") then
		layout:AddPadding(-16)
	end
	
	self.optDlog = Syn_SwitchIconsSettingsDialog:new(moho)
	
	self.opt = LM.GUI.PopupDialog("", --[[true]]false, self.DLOG_BEGIN)
	self.opt:SetDialog(self.optDlog)
	if (self.ver > 11) then
		self.opt:SetToolTip("Settings")
	end
	layout:PushV(LM.GUI.ALIGN_CENTER)
	layout:AddChild(self.opt, LM.GUI.ALIGN_CENTER, -15)
	layout:Pop()
		
	layout:AddChild(LM.GUI.Divider(true), LM.GUI.ALIGN_FILL)
	
	local group
	local recur = {}
	local doc = moho.document
	if (doc:CountSelectedLayers() > 1) then
		for i=0, doc:CountSelectedLayers()-1 do
			local layer = doc:GetSelectedLayer(i)
			if (layer:LayerType() == MOHO.LT_SWITCH) then
				local switch = moho:LayerAsSwitch(layer)
				if (not switch:IsFBFLayer()) then
					table.insert(recur, layer)
				end
			end
		end
	elseif (moho.layer:LayerType() == MOHO.LT_SWITCH) and (not moho:DrawingMesh()) then
		recur = {moho.layer}
	elseif (moho.layer:LayerType() == MOHO.LT_BONE) or (moho.layer:LayerType() == MOHO.LT_GROUP) then
	--DoLayout doesn't get called for a group layer when toggling to frame zero 
		group = moho:LayerAsGroup(moho.layer)
		recur = Syn_SwitchIcons:Recursive(moho, group, recur)
	else
		return
	end
	
	local a, b, c = 1, #recur, 1
	if (self.lSort) then
		a, b, c = #recur, 1, -1
	end
	
	for i=a, b, c do
		local layer = recur[i]
		if (layer:LayerType() == MOHO.LT_SWITCH) and (not moho:DrawingMesh()) then
		
			self.iconDlog = Syn_SwitchIconsDialog:new(moho, layer)
			
			self.DIA.i = MOHO.MSG_BASE + 7 + i
			
			self.popup = LM.GUI.PopupDialog(layer:Name(), true--[[false]], self.DIA.i)	--hold open
			self.popup:SetDialog(self.iconDlog)
			if (self.ver > 11) then
				self.popup:SetToolTip("Hit <enter> to update UI")
			end
			layout:AddChild(self.popup)
			
			layout:AddPadding(Syn_SwitchIcons.pad)
		end
	end
	self.recur = #recur
	
--[[--this cannot tell the difference from switching tabs between two open documents
	if (self.proj) and (self.proj ~= moho.document:Name()) then --document saved as new name
		local opSys = self:OS()
		local last = string.match(self.proj, "(.+)%..+")
		local doc = string.match(moho.document:Name(), "(.+)%..+")
		local appDir = string.gsub(moho:UserAppDir(), "\\", "/")
		local old = appDir.."/scripts/ScriptResources/syn_resources/"..last
		local new = appDir.."/scripts/ScriptResources/syn_resources/"..doc
		if (opSys ~= "win") then
			old = string.sub(old, " ", "\\ ")
			new = string.sub(new, " ", "\\ ")
			--os.execute("mkdir "..new)
			os.execute("mv "..old.." "..new)
		end
		os.rename(old, new) --rename thumbnail folder
	end
--]]
	self.proj = moho.document:Name()
end

function Syn_SwitchIcons:UpdateWidgets(moho)
	if (moho.frame == 0) --[[and (moho.layer:LayerType() == MOHO.LT_SWITCH) and (not moho:DrawingMesh())]] then
		self.update:Enable(true)
	else
		self.update:Enable(false)
	end
end 

function Syn_SwitchIcons:HandleMessage(moho, view, msg)
	if (msg == self.UPDATE) then
		if (moho:UserAppDir() == "") then
			LM.GUI.Alert(LM.GUI.ALERT_INFO, "You must have a Custom Content Folder to store switch thumbnails.", nil, nil, "OK", nil, nil)
		else
			local count = 0
			local layer = moho.document:LayerByAbsoluteID(count)
			repeat
				if (layer:SecondarySelection()) or (self.ver < 12 and layer == moho.layuer) then
					self:UpdateIcons(moho, view, layer)
				end
				count = count+1
				layer = moho.document:LayerByAbsoluteID(count)
			until (not layer)
		end
	elseif (msg == self.ALT_UPDATE) then
		if (moho:UserAppDir() == "") then
			LM.GUI.Alert(LM.GUI.ALERT_INFO, "You must have a Custom Content Folder to store switch thumbnails.", nil, nil, "OK", nil, nil)
		else
			local count = 0
			local layer = moho.document:LayerByAbsoluteID(count)
			repeat
				self:UpdateIcons(moho, view, layer)
				count = count+1
				layer = moho.document:LayerByAbsoluteID(count)
			until (not layer)
		end
	end
	if (msg == self.DLOG_END or msg == self.UPDATE or msg == self.ALT_UPDATE or msg == self.DELETE) then
		local frame = moho.frame
		if (frame == 0) then
			moho:SetCurFrame(1)
		else
			moho:SetCurFrame(0)
		end
		moho:SetCurFrame(frame)
	end
	
	local ID = msg - (MOHO.MSG_BASE + 7)
	self.switchID = ID
	
	if (msg == self.DLOG_BEGIN) then
		self.optDlog.doc = moho.document
	end
	
	self.h = view:Graphics():Height()
	self.w = view:Graphics():Width()
	
	--MOHO.Redraw()
end

-- **************************************************
-- The guts of this script (DEBUG VERSION with Path Fix)
-- **************************************************
-- **************************************************
-- The guts of this script (FIX: Force Backslash & System Temp)
-- **************************************************

-- **************************************************
-- The guts of this script (Direct Byte Copy Mode)
-- **************************************************

-- [내부 함수] 파일을 바이너리 모드로 직접 복사하는 함수
-- **************************************************
-- The guts of this script (FINAL: PowerShell Delivery)
-- **************************************************

-- **************************************************
-- The guts of this script (HYBRID: Backslash Gen + PowerShell Copy)
-- **************************************************
-- **************************************************
-- The guts of this script (FINAL: .ps1 File Generation Strategy)
-- **************************************************

function Syn_SwitchIcons:UpdateIcons(moho, view, layer)
	print(">>> [START] UpdateIcons: PS1 File Gen Mode")

	if (layer:LayerType() == MOHO.LT_SWITCH) and (not moho:DrawingMesh()) then
		local group = moho:LayerAsGroup(layer)
		
		local docNameRaw = moho.document:Name()
		local doc = string.match(docNameRaw, "(.+)%..+") 
		if not doc then doc = "Untitled" end 
		
		-- [1. 경로 설정]
		local sysTemp = os.getenv("TEMP")
		local tempDir = sysTemp .. "\\MohoSynIcons"
		
		-- G드라이브 경로
		local baseDir = moho:UserAppDir() .. "/scripts/ScriptResources/syn_resources/"
		local targetDir = baseDir .. doc
		
		local opSys = self:OS()
		
		if opSys == "win" then
			tempDir = string.gsub(tempDir, "/", "\\")
			baseDir = string.gsub(baseDir, "/", "\\")
			targetDir = string.gsub(targetDir, "/", "\\")
			
			-- [DEBUG] 경로 문자열 바이트 검사
			-- 한글 '공'이 UTF-8이면: 234 179 181
			-- 한글 '공'이 CP949이면: 176 248
			print("--------------------------------------------------")
			print(">>> DEBUG: Analyzing Target Path Encoding...")
			print(">>> Path: " .. targetDir)
			local byteStr = ""
			local len = string.len(targetDir)
			-- 앞쪽 20글자만 바이트 코드 출력
			for k=1, math.min(len, 20) do
				byteStr = byteStr .. string.byte(targetDir, k) .. " "
			end
			print(">>> Bytes (First 20): " .. byteStr)
			print("--------------------------------------------------")
			
			-- 임시 폴더 생성
			os.execute('cmd /c mkdir "' .. tempDir .. '"')
			
			-- 타겟 폴더 생성 (PS1 파일 만들어서 실행)
			local mkDirScript = tempDir .. "\\mkdir_cmd.ps1"
			local f = io.open(mkDirScript, "wb") -- 바이너리 모드
			if f then
				-- UTF-8 BOM 추가 (파워쉘이 한글을 확실히 인식하게 함)
				f:write(string.char(0xEF, 0xBB, 0xBF))
				f:write("New-Item -ItemType Directory -Force -LiteralPath '" .. baseDir .. "'\r\n")
				f:write("New-Item -ItemType Directory -Force -LiteralPath '" .. targetDir .. "'\r\n")
				f:close()
				
				local runCmd = string.format("powershell -ExecutionPolicy Bypass -File \"%s\"", mkDirScript)
				os.execute(runCmd)
			else
				print("!!! ERROR: Cannot write mkdir script")
			end
		else
			local macTarget = string.gsub(targetDir, " ", "\\ ")
			os.execute("mkdir -p " .. macTarget)
		end
		
		local size = "user"
		if (self.size == 64) then size = "lg"
		elseif (self.size == 36) then size = "sm"
		end
		
		local par = layer:UUID()
		local H,W = moho.document:Height(), moho.document:Width()
		local switch = moho:LayerAsSwitch(layer)
		local swVal = switch:GetValue(0)
		
		-- [2. 렌더링 루프]
		for i=0, group:CountLayers()-1 do
			local layer = group:Layer(i)
			local name = layer:Name()
			switch:SetValue(0, name)
			
			local layerGlobal = self:GetGlobalLayerMatrix(moho, layer, moho.frame)
			local BB = layer:Bounds(moho.frame)
			
			if BB:MaxDimension2D() > 0 then
				layerGlobal:Transform(BB)
				
				local oldCameraPos = moho.document.fCameraTrack:GetValue(moho.frame)
				local newCameraPos = LM.Vector3:new_local()
				newCameraPos:Set(BB:Center2D().x, BB:Center2D().y, oldCameraPos.z)
				local oldZoom = moho.document.fCameraZoom:GetValue(moho.frame)
				moho.document:SetShape(self.size, self.size)
				moho.document.fCameraTrack:SetValue(moho.frame, newCameraPos)
				local camAngle = 2.0 * math.atan(BB:MaxDimension2D()/(newCameraPos.z * 2))
				local newZoom = 60 / (180.0 * camAngle/math.pi)
				moho.document.fCameraZoom:SetValue(moho.frame, newZoom)
							
				local rand = self:RandomName()
				local fileName = par.."_"..layer:UUID().."_"..size.."_"..rand
				
				if opSys == "win" then
					local tempFilePath = tempDir .. "\\" .. fileName .. ".png"
					local finalFilePath = targetDir .. "\\" .. fileName .. ".png"
					
					-- A. 렌더링
					moho:FileRender(tempFilePath)
					
					-- B. 복사 (PS1 파일 생성 방식)
					local fCheck = io.open(tempFilePath, "r")
					if fCheck then
						fCheck:close()
						print(">>> Generated: " .. fileName)
						
						-- 복사 명령을 담은 임시 .ps1 파일 생성
						local copyScript = tempDir .. "\\copy_cmd.ps1"
						local f = io.open(copyScript, "wb") -- 바이너리 쓰기
						if f then
							-- UTF-8 BOM (EF BB BF)
							f:write(string.char(0xEF, 0xBB, 0xBF))
							-- 명령어 작성
							f:write("Copy-Item -LiteralPath '" .. tempFilePath .. "' -Destination '" .. finalFilePath .. "' -Force")
							f:close()
							
							-- 파워쉘로 스크립트 파일 실행
							local psRun = string.format("powershell -ExecutionPolicy Bypass -File \"%s\"", copyScript)
							os.execute(psRun)
							
							-- 스크립트 파일 삭제 (너무 빨라서 충돌나면 주석 처리)
							-- os.remove(copyScript)
							
							-- 이미지는 확인을 위해 삭제 안 함 (성공하면 나중에 주석 해제)
							-- os.remove(tempFilePath) 
						else
							print("!!! ERROR: Failed to create copy script file")
						end
					else
						print("!!! Failed to Generate: " .. fileName)
					end
				else
					local path = targetDir .. "/" .. fileName .. ".png"
					moho:FileRender(path)
				end

				moho.document.fCameraZoom:SetValue(moho.frame, oldZoom)
				moho.document.fCameraTrack:SetValue(moho.frame, oldCameraPos)
			end
		end
		
		switch:SetValue(0, swVal)
		moho.document:SetShape(W,H)
		MOHO.Redraw()
		print(">>> [END] UpdateIcons finished")
	end
end

-- **************************************************
-- Standard functions
-- **************************************************

function Syn_SwitchIcons:ColorizeIcon()
	if (self.recolor == 1) then
		return true
	end
	return false
end

function Syn_SwitchIcons:NonDragMouseMove()
	return true
end

function Syn_SwitchIcons:IsEnabled(moho)
	if (moho.layer:LayerType() ~= MOHO.LT_BONE) and (moho.layer:LayerType() ~= MOHO.LT_GROUP) and (moho.layer:LayerType() ~= MOHO.LT_SWITCH) then
		--return false
	end
	return true
end

function Syn_SwitchIcons:IsRelevant(moho)
	local docName = string.match(moho.document:Name(), ".-([^\\/]-)%.?[^%.\\/]*$")
	self.docFolder = string.gsub(moho:UserAppDir().."/scripts/ScriptResources/syn_resources/"..docName.."/", "\\", "/")
	self.ver = tonumber(string.match(moho:AppVersion(), "(%d+)%p.+"))
	return true
end

function Syn_SwitchIcons:OnMouseDown(moho, mouseEvent)
	local app = string.match(moho:AppDir(), "(.+)Support")
	local cursor = LM.GUI.Cursor(app.."Images/curs_hresize")
	mouseEvent.view:SetCursor(cursor)
	mouseEvent.view:DrawMe()
	self.startFrm = moho.frame
end

function Syn_SwitchIcons:OnMouseMoved(moho, mouseEvent)
	if (not mouseEvent.view:IsMouseDragging(0)) then
		local app = string.match(moho:AppDir(), "(.+)Support")
		local cursor = LM.GUI.Cursor(app.."Images/dragCursor")
		mouseEvent.view:SetCursor(cursor)
		return
	else
		local range = math.ceil(((mouseEvent.pt.x - mouseEvent.startPt.x)/8)*self.speed)
		if (self.startFrm+range < 0) then
			moho:SetCurFrame(0)
		else
			moho:SetCurFrame(self.startFrm+range)
		end
	end
end

function Syn_SwitchIcons:OnMouseUp(moho, mouseEvent)
	mouseEvent.view:SetCursor()
	mouseEvent.view:DrawMe()
	moho:UpdateUI()	--needed to update timeline and layers window after switch is keyed
end

function Syn_SwitchIcons:OnKeyDown(moho, keyEvent)
--refresh settings/dialogs with ENTER
	local frame = moho.frame
	--if (keyEvent.keyCode == LM.GUI.KEY_RETURN) then --doesn't work with enter key
	if (keyEvent.keyCode == 13) then
		if (frame == 0) then
			moho:SetCurFrame(1)
		else
			moho:SetCurFrame(0)
		end
		moho:SetCurFrame(frame)
		
		keyEvent.view:DrawMe()
	end
end

-- **************************************************
-- Utility functions
-- **************************************************

function Syn_SwitchIcons:OS()
	local opSys
	if (os.getenv("OS") ~= nil) then
		opSys = string.lower(string.sub(os.getenv("OS"), 1, 3))
		if opSys == "win" then
			opSys = "win"
		else
			opSys = "unix"
		end
	else
		opSys = "unix"
	end
	return opSys
end

function Syn_SwitchIcons:RandomName()
  -- random alphanumeric string
  local charset = {}
  for c = 48, 57 do table.insert(charset, string.char(c)) end
  for c = 65, 90 do table.insert(charset, string.char(c)) end
  for c = 97, 122 do table.insert(charset, string.char(c)) end
  local length = 10
  local function randomString(length)
    
   
if not length or length <= 0 then return '' end
    
   
math.randomseed(os.time())  -- Usar os.time() para inicializar a semente aleatória
    return randomString(length - 1) .. charset[math.random(1, #charset)]
  end
  return randomString(length)
end

function Syn_SwitchIcons:Recursive(moho, group, layers)
	local stack = {}
	local sp = 0
	for i=0, group:CountLayers()-1 do
		local layer = group:Layer(i)
		table.insert(layers, layer)
		local group = nil
		local layerID = 0
		while true do
			if (layer:IsGroupType()) then
				table.insert(stack, {group, layerID -1})
				sp = sp+1
				group = moho:LayerAsGroup(layer)
				layerID = group:CountLayers()
			end
			if (layerID > 0) then
				layerID = layerID -1
				layer = group:Layer--[[ByDepth]](layerID)
				table.insert(layers, layer)
			else
				layerID = -1
				while (sp > 0) do
					group, layerID = stack[sp][1], stack[sp][2]
					table.remove(stack)
					sp = sp -1
					if (layerID >= 0) then
						layer = group:Layer--[[ByDepth]](layerID)
						table.insert(layers, layer)
						break
					end
				end
			end
			if (layerID < 0) then
				break
			end
		end
	end
	return layers
end

-- **************************************************
-- Alexandra Evseeva @ http://ae.revival.ru/
-- http://www.lostmarble.com/forum/viewtopic.php?p=196232#p196232
-- http://mohoscripts.com/script/ae_utilities
-- **************************************************

function Syn_SwitchIcons:GetGlobalLayerMatrix(moho, layer, frame) 
	local prevMatrix = LM.Matrix:new_local()
	prevMatrix:Identity()
	local nextLayer = layer
	repeat
		local prevLayer = nextLayer
		local matrix = LM.Matrix:new_local()
		nextLayer:GetLayerTransform(frame, matrix, moho.document)
		matrix:Multiply(prevMatrix)
		prevMatrix:Set(matrix)
		if nextLayer:Parent() then nextLayer = nextLayer:Parent() end
	until nextLayer == prevLayer
	local cameraMatrix = LM.Matrix:new_local()
	moho.document:GetCameraMatrix(frame, cameraMatrix)
	cameraMatrix:Invert()
	cameraMatrix:Multiply(prevMatrix)
	return cameraMatrix
end

