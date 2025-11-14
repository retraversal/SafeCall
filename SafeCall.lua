--[[
	Author: Akira
	SafeCall v1.2
	Lightweight fail-safe wrapper for unsafe function calls
	
	Features:
	• Automatic error handling with pcall
	• Retry mechanisms with configurable attempts
	• Promise-based async calls
	• Table function protection
	• RemoteEvent/RemoteFunction wrappers
	• Custom logging support
	• Circuit breaker pattern
	• Rate limiting
	• Memory-safe connections
	• Memoization with TTL
	• Performance profiling
	• Global error handlers
	• Promise Support
	• Context Tags
	• Error Filtering
	• Dynamic Retry
	• Safe Task Scheduler
--]]

local SafeCall = {}
SafeCall.__index = SafeCall

local RunService = game:GetService("RunService")

local ok, Promise = pcall(function()
	return require(game:GetService("ReplicatedStorage").Main.Frameworks.Packages.Promise)
end)
if not ok then Promise = nil end

SafeCall._globalHandlers = {}
SafeCall._errorFilters = {}
SafeCall._taskScheduler = {}
SafeCall._retryHandler = nil

function SafeCall.new(logFunction)
	local instance = {
		Log = logFunction or function(err)
			warn("[SafeCall]:", err)
		end,
		_retryDefaults = {
			attempts = 3,
			delay = 0.1,
			backoff = 1.5
		}
	}
	return setmetatable(instance, SafeCall)
end

function SafeCall.call(fn, ...)
	local success, result = pcall(fn, ...)
	if not success then
		warn("[SafeCall]:", result)
	end
	return success, result
end

function SafeCall:SetLogger(fn)
	self.Log = fn
	return self
end

function SafeCall:SetRetryDefaults(attempts, delay, backoff)
	self._retryDefaults = {
		attempts = attempts or 3,
		delay = delay or 0.1,
		backoff = backoff or 1.5
	}
	return self
end

function SafeCall:AddErrorIgnorePattern(pattern)
	table.insert(SafeCall._errorFilters, pattern)
end

function SafeCall:SetRetryHandler(fn)
	SafeCall._retryHandler = fn
end

function SafeCall:Call(fn, contextTag, ...)
	local success, result = pcall(fn, ...)
	if not success then
		for _, pattern in ipairs(SafeCall._errorFilters) do
			if string.match(result, pattern) then
				return success, result -- Ignore filtered error
			end
		end

		local context = contextTag and ("[" .. contextTag .. "] ") or ""
		self.Log(context .. result)

		for _, handler in ipairs(SafeCall._globalHandlers) do
			pcall(handler, result, debug.traceback(), contextTag)
		end
	end
	return success, result
end

function SafeCall:CallWithRetry(fn, attempts, delay, backoff, ...)
	attempts = attempts or self._retryDefaults.attempts
	delay = delay or self._retryDefaults.delay
	backoff = backoff or self._retryDefaults.backoff
	
	local args = {...}
	local currentDelay = delay
	
	for i = 1, attempts do
		local success, result = pcall(fn, table.unpack(args))
		if success then return true, result end

		if SafeCall._retryHandler and not SafeCall._retryHandler(result) then
			break
		end

		self.Log(`[Retry {i}/{attempts}] {result}`)
		if i < attempts then
			task.wait(currentDelay)
			currentDelay = currentDelay * backoff
		end
	end

	return false, "All retry attempts failed"
end

function SafeCall:SetPromiseModule(promiseModule)
	self.Promise = promiseModule
end

function SafeCall:CallAsync(fn, ...)
	if not self.Promise then
		error("No Promise module provided. Use SafeCall:SetPromiseModule(Promise)")
	end

	local args = { ... }

	return self.Promise.new(function(resolve, reject)
		local success, result = pcall(fn, table.unpack(args))
		if success then
			resolve(result)
		else
			self.Log(result)
			reject(result)
		end
	end)
end

function SafeCall:CallDeferred(fn, ...)
	local args = {...}
	task.defer(function()
		self:Call(fn, table.unpack(args))
	end)
end

function SafeCall:CallDelayed(delay, fn, ...)
	local args = {...}
	task.wait(delay)
	return self:Call(fn, table.unpack(args))
end

function SafeCall:ProtectTable(tbl)
	local protected = {}
	for k, v in pairs(tbl) do
		if typeof(v) == "function" then
			protected[k] = function(...)
				return self:Call(v, ...)
			end
		else
			protected[k] = v
		end
	end
	return protected
end

function SafeCall:WrapEvent(remote, callback)
	assert(remote and typeof(callback) == "function", "Invalid arguments for WrapEvent")

	if remote:IsA("RemoteEvent") then
		if RunService:IsServer() then
			return remote.OnServerEvent:Connect(function(player, ...)
				self:Call(callback, player, ...)
			end)
		else
			return remote.OnClientEvent:Connect(function(...)
				self:Call(callback, ...)
			end)
		end
	elseif remote:IsA("BindableEvent") then
		return remote.Event:Connect(function(...)
			self:Call(callback, ...)
		end)
	else
		error("Expected RemoteEvent or BindableEvent")
	end
end

function SafeCall:WrapFunction(remote, callback)
	assert(remote and typeof(callback) == "function", "Invalid arguments for WrapFunction")

	if remote:IsA("RemoteFunction") then
		if RunService:IsServer() then
			remote.OnServerInvoke = function(player, ...)
				local success, result = self:Call(callback, player, ...)
				return success and result or nil
			end
		else
			remote.OnClientInvoke = function(...)
				local success, result = self:Call(callback, ...)
				return success and result or nil
			end
		end
	elseif remote:IsA("BindableFunction") then
		remote.OnInvoke = function(...)
			local success, result = self:Call(callback, ...)
			return success and result or nil
		end
	else
		error("Expected RemoteFunction or BindableFunction")
	end
end

function SafeCall:CallBatch(functions)
	local results = {}
	for i, fn in ipairs(functions) do
		results[i] = {self:Call(fn)}
	end
	return results
end

function SafeCall:CallWithTimeout(timeout, fn, ...)
	local args = {...}
	local completed = false
	local result

	task.spawn(function()
		result = {self:Call(fn, table.unpack(args))}
		completed = true
	end)

	local startTime = tick()
	while not completed and (tick() - startTime) < timeout do
		task.wait()
	end

	if completed then
		return table.unpack(result)
	else
		self.Log("Function call timed out after " .. timeout .. " seconds")
		return false, "Timeout"
	end
end

function SafeCall:CreateCircuitBreaker(threshold, resetTime)
	return {
		failures = 0,
		threshold = threshold or 5,
		resetTime = resetTime or 30,
		lastFailure = 0,
		state = "CLOSED" -- CLOSED, OPEN, HALF_OPEN
	}
end

function SafeCall:CallWithCircuitBreaker(breaker, fn, ...)
	local now = tick()

	if breaker.state == "OPEN" and (now - breaker.lastFailure) > breaker.resetTime then
		breaker.state = "HALF_OPEN"
		breaker.failures = 0
	end

	if breaker.state == "OPEN" then
		self.Log("Circuit breaker is OPEN - rejecting call")
		return false, "Circuit breaker open"
	end

	local success, result = self:Call(fn, ...)

	if success then
		if breaker.state == "HALF_OPEN" then
			breaker.state = "CLOSED"
		end
		breaker.failures = 0
	else
		breaker.failures = breaker.failures + 1
		breaker.lastFailure = now

		if breaker.failures >= breaker.threshold then
			breaker.state = "OPEN"
			self.Log(`Circuit breaker OPENED after {breaker.failures} failures`)
		end
	end

	return success, result
end

function SafeCall:CreateRateLimiter(maxCalls, timeWindow)
	return {
		calls = {},
		maxCalls = maxCalls or 10,
		timeWindow = timeWindow or 60
	}
end

function SafeCall:CallWithRateLimit(limiter, fn, ...)
	local now = tick()

	for i = #limiter.calls, 1, -1 do
		if (now - limiter.calls[i]) > limiter.timeWindow then
			table.remove(limiter.calls, i)
		end
	end

	if #limiter.calls >= limiter.maxCalls then
		self.Log("Rate limit exceeded")
		return false, "Rate limited"
	end

	table.insert(limiter.calls, now)
	return self:Call(fn, ...)
end

function SafeCall:ConnectSafe(signal, callback, options)
	options = options or {}
	local usePromise = options.usePromise
	local weakRef = options.weakRef

	local connection
	connection = signal:Connect(function(...)
		local args = { ... }

		if weakRef and not weakRef.Parent then
			connection:Disconnect()
			return
		end

		if usePromise and self.Promise then
			self.Promise.new(function(resolve, reject)
				local success, result = pcall(function()
					return callback(table.unpack(args))
				end)

				if success then
					resolve(result)
				else
					self.Log(result)
					reject(result)
				end
			end)
		else
			local success, result = pcall(function()
				return callback(table.unpack(args))
			end)

			if not success then
				self.Log(result)
			end
		end
	end)

	return connection
end

function SafeCall:Memoize(fn, ttl)
	local cache = {}
	ttl = ttl or math.huge

	return function(...)
		local key = table.concat({...}, "_")
		local entry = cache[key]

		if entry and (tick() - entry.time) < ttl then
			return entry.success, entry.result
		end

		local success, result = self:Call(fn, ...)
		cache[key] = {
			success = success,
			result = result,
			time = tick()
		}

		return success, result
	end
end

function SafeCall:CreateProfiler()
	return {
		calls = 0,
		totalTime = 0,
		errors = 0,
		slowCalls = 0,
		slowThreshold = 0.1
	}
end

function SafeCall:CallWithProfiler(profiler, fn, ...)
	local start = tick()
	profiler.calls = profiler.calls + 1

	local success, result = self:Call(fn, ...)

	local duration = tick() - start
	profiler.totalTime = profiler.totalTime + duration

	if not success then
		profiler.errors = profiler.errors + 1
	end

	if duration > profiler.slowThreshold then
		profiler.slowCalls = profiler.slowCalls + 1
	end

	return success, result
end

function SafeCall:GetProfilerStats(profiler)
	return {
		calls = profiler.calls,
		errors = profiler.errors,
		errorRate = profiler.calls > 0 and (profiler.errors / profiler.calls) or 0,
		avgTime = profiler.calls > 0 and (profiler.totalTime / profiler.calls) or 0,
		slowCalls = profiler.slowCalls,
		slowCallRate = profiler.calls > 0 and (profiler.slowCalls / profiler.calls) or 0
	}
end

function SafeCall:AddGlobalHandler(handler)
	table.insert(SafeCall._globalHandlers, handler)
end

function SafeCall:RemoveGlobalHandler(handler)
	for i, h in ipairs(SafeCall._globalHandlers) do
		if h == handler then
			table.remove(SafeCall._globalHandlers, i)
			break
		end
	end
end

function SafeCall:Schedule(name, interval, fn)
	if SafeCall._taskScheduler[name] then return end -- prevent duplicate
	SafeCall._taskScheduler[name] = true

	task.spawn(function()
		while SafeCall._taskScheduler[name] do
			self:Call(fn, name)
			task.wait(interval)
		end
	end)
end

function SafeCall:StopSchedule(name)
	SafeCall._taskScheduler[name] = nil
end

return SafeCall
