local M = {}
M._VERSION = "1.0.0"
M._AUTHOR = "Weegee_MLG / Skin Walke Team"

local ins, cat = table.insert, table.concat
local tostr = tostring
local clock = (os and os.clock) or function() return 0 end

local getrawmt = getrawmetatable or (debug and debug.getmetatable)
local setreadonly_ = setreadonly or (function() end)
local isreadonly_ = isreadonly or function() return false end
local getnamecall = getnamecallmethod or (function() return nil end)
local checkcaller_ = checkcaller or function() return false end

local function have(f) return type(f) == "function" end

local function shortVal(v)
	local t = type(v)
	if t == "string" then
		if #v > 40 then return "\"" .. v:sub(1, 37) .. "...\"" end
		return "\"" .. v .. "\""
	elseif t == "table" then
		return "table"
	elseif t == "userdata" then
		local ok, s = pcall(tostr, v)
		return ok and s or "userdata"
	else
		return tostr(v)
	end
end

local function classOf(o)
	local ok, c = pcall(function() return o.ClassName end)
	if ok then return c end
	return nil
end

local function nameOf(o)
	local ok, n = pcall(function() return o.Name end)
	if ok then return n end
	return nil
end

local Registry = {}
Registry.__index = Registry

function M.new()
	local self = setmetatable({}, Registry)
	self.rules = {}
	self.log = {}
	self.installed = {}
	self.originals = {}
	self.active = false
	self.maxLog = 500
	self.seq = 0
	self.logArgs = true
	self._needsMeta = false
	return self
end

local function callOrig(kind, orig, self_obj, method, ...)
	if kind == "index" then return orig(self_obj, method) end
	return orig(self_obj, ...)
end

local function safeRead(origIndex, o, key)
	if origIndex then
		local ok, v = pcall(origIndex, o, key)
		if ok then return v end
	end
	return nil
end

local function ruleMatches(rule, ctx)
	if rule.method ~= nil then
		if type(rule.method) == "table" then
			local hit = false
			for _, m in ipairs(rule.method) do if m == ctx.method then hit = true break end end
			if not hit then return false end
		elseif rule.method ~= ctx.method then
			return false
		end
	end
	if rule.class ~= nil and rule.class ~= ctx.class then return false end
	if rule.name ~= nil and rule.name ~= ctx.name then return false end
	if have(rule.match) then
		local ok, res = pcall(rule.match, ctx)
		if not ok or not res then return false end
	end
	return true
end

function Registry:record(entry)
	self.seq = self.seq + 1
	entry.i = self.seq
	entry.t = clock()
	self.log[#self.log + 1] = entry
	if #self.log > self.maxLog then
		table.remove(self.log, 1)
	end
end

function Registry:_recompute()
	local needs = false
	for _, r in ipairs(self.rules) do
		if r.enabled ~= false and (r.class ~= nil or r.name ~= nil or have(r.match)) then
			needs = true
			break
		end
	end
	self._needsMeta = needs
end

function Registry:addRule(rule)
	assert(type(rule) == "table", "walkekernel: rule must be a table")
	rule.action = rule.action or "log"
	rule.id = rule.id or ("rule" .. (#self.rules + 1))
	self.rules[#self.rules + 1] = rule
	self:_recompute()
	return rule.id
end

function Registry:removeRule(id)
	for i = #self.rules, 1, -1 do
		if self.rules[i].id == id then
			table.remove(self.rules, i)
			self:_recompute()
			return true
		end
	end
	return false
end

function Registry:clearRules()
	self.rules = {}
	self._needsMeta = false
end

function Registry:firstMatch(ctx)
	for _, rule in ipairs(self.rules) do
		if rule.enabled ~= false and ruleMatches(rule, ctx) then
			return rule
		end
	end
	return nil
end

local function argList(n, ...)
	local p = {}
	for i = 1, n do p[i] = shortVal((select(i, ...))) end
	return cat(p, ", ")
end

function Registry:_dispatch(kind, orig, self_obj, method, ...)
	if self._inside or #self.rules == 0 then
		return callOrig(kind, orig, self_obj, method, ...)
	end
	self._inside = true

	local class, name
	if self._needsMeta then
		local origIndex = self.originals.__index
		class = safeRead(origIndex, self_obj, "ClassName")
		name = safeRead(origIndex, self_obj, "Name")
	end

	local ctx = {
		kind = kind,
		method = method,
		class = class,
		name = name,
		object = self_obj,
		nargs = select("#", ...),
		fromExecutor = checkcaller_(),
	}
	local rule = self:firstMatch(ctx)

	if not rule then
		self._inside = false
		return callOrig(kind, orig, self_obj, method, ...)
	end

	local act = rule.action
	if self.logArgs then
		self:record({
			rule = rule.id, kind = kind, method = method, class = class,
			action = act, args = "(" .. argList(ctx.nargs, ...) .. ")",
		})
	else
		self:record({ rule = rule.id, kind = kind, method = method, class = class, action = act, args = "" })
	end

	if act == "log" then
		self._inside = false
		return callOrig(kind, orig, self_obj, method, ...)
	end

	local isIndex = kind == "index"
	local n = isIndex and 1 or select("#", ...)
	local packed = isIndex and { method } or { ... }
	local runner = function()
		if act == "block" then
			if rule.returns ~= nil then
				if type(rule.returns) == "function" then return rule.returns(ctx, table.unpack(packed, 1, n)) end
				return rule.returns
			end
			return nil
		elseif act == "reroute" then
			if have(rule.remap) then
				if isIndex then
					return orig(self_obj, (rule.remap(ctx, method)))
				end
				return orig(self_obj, rule.remap(ctx, table.unpack(packed, 1, n)))
			end
			return callOrig(kind, orig, self_obj, method, table.unpack(packed, 1, n))
		elseif act == "replace" then
			if have(rule.with) then
				return rule.with(ctx, orig, self_obj, table.unpack(packed, 1, n))
			end
			return callOrig(kind, orig, self_obj, method, table.unpack(packed, 1, n))
		else
			return callOrig(kind, orig, self_obj, method, table.unpack(packed, 1, n))
		end
	end

	local res = table.pack(pcall(runner))
	self._inside = false
	if not res[1] then error(res[2], 0) end
	return table.unpack(res, 2, res.n)
end

function Registry:hook(target)
	assert(target ~= nil, "walkekernel: hook target is nil")
	if not have(getrawmt) then
		return false, "no getrawmetatable available on this executor"
	end
	local mt = getrawmt(target)
	if type(mt) ~= "table" then
		return false, "target has no accessible metatable"
	end

	local wasReadonly = isreadonly_(mt)
	if wasReadonly and have(setreadonly) then pcall(setreadonly_, mt, false) end

	local kernel = self
	self._target = target

	if have(hookmetamethod) then
		self._native = true
		local origN
		local okN
		okN, origN = pcall(hookmetamethod, target, "__namecall", function(self_obj, ...)
			local m = getnamecall()
			return kernel:_dispatch("namecall", origN, self_obj, m, ...)
		end)
		if okN then self.originals.__namecall = origN self.installed.__namecall = true end

		local origI
		local okI
		okI, origI = pcall(hookmetamethod, target, "__index", function(self_obj, key)
			return kernel:_dispatch("index", origI, self_obj, key)
		end)
		if okI then self.originals.__index = origI self.installed.__index = true end
	else
		local rawnc = rawget(mt, "__namecall")
		if type(rawnc) == "function" then
			self.originals.__namecall = rawnc
			rawset(mt, "__namecall", function(self_obj, ...)
				local m = getnamecall()
				return kernel:_dispatch("namecall", rawnc, self_obj, m, ...)
			end)
			self.installed.__namecall = true
		end
		local rawidx = rawget(mt, "__index")
		if type(rawidx) == "function" then
			self.originals.__index = rawidx
			rawset(mt, "__index", function(self_obj, key)
				return kernel:_dispatch("index", rawidx, self_obj, key)
			end)
			self.installed.__index = true
		end
		self._mt = mt
		self._restoreReadonly = wasReadonly
	end

	if wasReadonly and not have(hookmetamethod) and have(setreadonly) then
		pcall(setreadonly_, mt, true)
	end

	self.active = next(self.installed) ~= nil
	if not self.active then
		return false, "could not install any metamethod hook"
	end
	return true
end

function Registry:unhook()
	local restored = {}
	if self._mt then
		local mt = self._mt
		if have(setreadonly) then pcall(setreadonly_, mt, false) end
		if self.installed.__namecall and self.originals.__namecall then
			rawset(mt, "__namecall", self.originals.__namecall)
			restored.__namecall = true
		end
		if self.installed.__index and self.originals.__index then
			rawset(mt, "__index", self.originals.__index)
			restored.__index = true
		end
		if self._restoreReadonly and have(setreadonly) then pcall(setreadonly_, mt, true) end
	elseif self._native and have(hookmetamethod) and self._target then
		if self.installed.__namecall and self.originals.__namecall then
			local ok = pcall(hookmetamethod, self._target, "__namecall", self.originals.__namecall)
			restored.__namecall = ok
		end
		if self.installed.__index and self.originals.__index then
			local ok = pcall(hookmetamethod, self._target, "__index", self.originals.__index)
			restored.__index = ok
		end
	end
	self.installed = {}
	self.active = false
	self._restored = restored
	return true
end

function Registry:report()
	local out = {}
	out[#out + 1] = "== Walke Kernel =="
	out[#out + 1] = "active: " .. tostr(self.active)
	local hooks = {}
	for k in pairs(self.installed) do hooks[#hooks + 1] = k end
	out[#out + 1] = "hooks:  " .. (next(hooks) and cat(hooks, ", ") or "none")
	out[#out + 1] = "rules:  " .. #self.rules
	out[#out + 1] = ""
	out[#out + 1] = "recent activity (" .. #self.log .. "):"
	local shown = 0
	for i = #self.log, 1, -1 do
		if shown >= 30 then break end
		shown = shown + 1
		local e = self.log[i]
		out[#out + 1] = "  [" .. e.action .. "] " .. tostr(e.class or "?") .. ":" .. tostr(e.method) .. " " .. e.args
	end
	if #self.log == 0 then out[#out + 1] = "  nothing logged yet" end
	return cat(out, "\n")
end

M.Registry = Registry
return M
