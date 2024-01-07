local STATS_MAX <const> = 1024

-- classes for typing.
-- NOTE: metatable classes do not cross VM's, so they may only be used in the
-- same VM they were assigned (pools or routes)
local CommandMap = {}
local RouteConf = {}

local function module_defaults(old)
    local stats = {
        map = {},
        freelist = {},
        next_id = 1,
    }
    if old and old.stats then
        stats = old.stats
    end
    return {
        c_in = {
            pools = {},
            routes = {},
        },
        stats = stats,
    }
end
local M = module_defaults()

-- https://stackoverflow.com/questions/9168058/how-to-dump-a-table-to-console
-- should probably get a really nice one of these for the library instead.
local function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end

--
-- User interface functions
--

function settings(a)
    if M.is_debug then
        print("settings:")
        print(dump(a))
    end
    M.c_in.settings = a
end

function pools(a)
    if M.is_debug then
        print("pools config:")
        print(dump(a))
    end
    M.c_in.pools = a
end

function routes(a)
    dsay("routes:")
    dsay(dump(a))
    if a["conf"] == nil then
        a["conf"] = {}
    end

    if a.tag then
        M.c_in.routes[a.tag] = a
    else
        M.c_in.routes["default"] = a
    end
end

-- TODO: match regexp list against set of pools
function find_pools(m)
    error("unimplemented")
end

function local_zone(zone)
    dsay(zone)
    M.c.local_zone = zone
end

function verbose(opt)
    M.is_verbose = opt
    say("verbosity set to:", opt)
end

function debug(opt)
    M.is_debug = opt
    if M.is_debug or M.is_verbose then
        print("debug set to:", opt)
    end
end

function say(...)
    if M.is_verbose then
        print(...)
    end
end

function dsay(...)
    if M.is_debug then
        print(...)
    end
end

function cmdmap(t)
    for k, v in pairs(t) do
        if type(k) ~= "number" then
            error("cmdmap keys must all be numeric")
        end
    end
    return setmetatable(t, CommandMap)
end

--
-- User/Pool configuration thread functions
--

-- TODO: remember values and add to verbose print if changed on reload
local function settings_parse(a)
    local setters = {
        ["backend_connect_timeout"] = function(v)
            mcp.backend_connect_timeout(v)
        end,
        ["backend_retry_waittime"] = function(v)
            mcp.backend_retry_waittime(v)
        end,
        ["backend_read_timeout"] = function(v)
            mcp.backend_read_timeout(v)
        end,
        ["backend_failure_limit"] = function(v)
            mcp.backend_failure_limit(v)
        end,
        ["tcp_keepalive"] = function(v)
            mcp.tcp_keepalive(v)
        end,
        ["active_request_limit"] = function(v)
            mcp.active_req_limit(v)
        end,
        ["buffer_memory_limit"] = function(v)
            mcp.buffer_memory_limit(v)
        end,
        ["backend_flap_time"] = function(v)
            mcp.backend_flap_time(v)
        end,
        ["backend_flap_backoff_ramp"] = function(v)
            mcp.backend_flap_backoff_ramp(v)
        end,
        ["backend_flap_backoff_max"] = function(v)
            mcp.backend_flap_backoff_max(v)
        end,
    }

    -- TODO: throw error if setting unknown
    for setting, value in pairs(a) do
        local func = setters[setting]
        if func ~= nil then
            say("changing global setting:", setting, "to:", value)
            func(value)
        elseif setting == "poolopts" then
            error("unimplemented")
        end
    end
end

local function make_backend(name, host, o)
    local b = {}
    -- override per-backend options if requested
    if o ~= nil then
        for k, v in pairs(o) do
            b[k] = v
        end
    end

    if type(host) == "table" then
        for k, v in pairs(host) do
            b[k] = v
        end

        if b.host == nil then
            error("host missing from server entry")
        end
    else
        say("making backend for... " .. host)

        if string.match(host, "_down_$") then
            b.down = true
        end

        local ip, port, name = string.match(host, "^(.+):(%d+)%s+(%a+)")
        if ip ~= nil then
            b.host = ip
            b.port = port
            b.label = name
        else
            local ip, port = string.match(host, "^(.+):(%d+)")
            if ip ~= nil then
                b.host = ip
                b.port = port
            end
        end

        if b.host == nil then
            error(host .. " is an invalid backend string")
        end
    end

    -- create a default label out of the host:port if none directly supplied
    if b.label == nil then
        b.label = b.host .. ":" .. b.port
    end

    return mcp.backend(b)
end

-- converts a table describing pool objects into a new table of real pool
-- objects.
local function pools_parse(a)
    local pools = {}
    for name, conf in pairs(a) do
        local popts = conf.options
        local sopts = conf.server_options
        local s = {}
        -- TODO: some convenience functions for asserting?
        -- die more gracefully if server list missing
        for _, server in pairs(conf.servers) do
            table.insert(s, make_backend(name, server, sopts))
        end

        dsay("making pool:", name, "\n", dump(popts))
        pools[name] = mcp.pool(s, popts)
    end

    return pools
end

-- 1) walk keys looking for child*, recurse if RouteConfs are found
-- 2) resolve and call route.f
-- NOTE: this could be an actual function reference here...
-- 3) return the response directly. the _conf() function should wrap the next
-- stage itself.
local function configure_route(r, ctx)
    local route = r.a

    -- first, recurse and resolve any children.
    for k, v in pairs(route) do
        -- try to not accidentally coerce a non-string key into a string!
        if type(k) == "string" and string.find("^child", k) ~= nil then
            if type(v) == "table" then
                if (getmetatable(v) == RouteConf) then
                    route[k] = configure_route(v, ctx)
                else
                    -- it is a table of children.
                    for ck, cv in pairs(v) do
                        if type(cv) == "table" and (getmetatable(cv) == RouteConf) then
                            v[ck] = configure_route(cv, ctx)
                        end
                    end
                end
            end -- if "table"
        end -- if "child"
    end -- for(route)

    local f = _G[r.f]
    local ret = f(route, ctx)
    if ret == nil then
        error("route configure function failed to return anything: " .. r.f)
    end
    return ret
end

-- 1) walk the tree
-- 2) for each entrypoint, look for child_* keys
--  - check if metatable is RouteConf or not
-- 3) for each child entry with a table, run configure_route()
-- 4) resolve and run the .f function
-- 5) take the result of that and pack it:
--    { f = "route_name_start", a = t }
-- routes that have stats should assign stats or global overrides in this conf
-- stage.
-- NOTE: we are editing the entries in-place
local function configure_router(set)
    -- create ctx object to hold label + command
    local ctx = {
        label = function(self)
            return self._label
        end,
        cmd = function(self)
            return self._cmd
        end,
    }

    if set.map then
        -- a prefix map
        for mk, mv in pairs(set.map) do
            ctx._label = mk
            ctx._cmd = mcp.CMD_ANY_STORAGE
            if (getmetatable(mv) == CommandMap) then
                for cmk, cmv in pairs(mv) do
                    if (getmetatable(cmv) ~= RouteConf) then
                        error("bad entry in route table map")
                    end
                    -- replace the table entry
                    ctx._cmd = cmk
                    mv[cmk] = configure_route(cmv, ctx)
                end
            elseif (getmetatable(mv) == RouteConf) then
                set.map[mk] = configure_route(mv, ctx)
            else
                error("unknown route map type")
            end
        end
    else
        -- a command map
        ctx._label = "default"
        -- walk set.cmap instead
        for cmk, cmv in pairs(set.cmap) do
            ctx._cmd = cmk
            set.cmap[cmk] = configure_route(cmv, ctx)
        end
    end

    if set.default then
        ctx._label = "default"
        ctx._cmd = mcp.CMD_ANY_STORAGE
        set.default = configure_route(set.default, ctx)
    end
end

-- TODO: allow a way to override which attach() happens for a router.
-- by default we just do CMD_ANY_STORAGE
-- NOTE: this function should be used for vadliating/preparsing the router
-- config and routes sections.
local function routes_parse(routes, pools)
    for tag, set in pairs(routes) do
        if set.map and set.cmap then
            error("cannot set both map and cmap for a router")
        end

        if set.map == nil and set.cmap == nil then
            error("must pass map or cmap to a router")
        end

        configure_router(set)
    end

    return { r = routes, p = pools }
end

-- route*() config functions can call this to get ids to use for stats counters
function stats_get_id(name)
    local st = M.stats

    -- already have an ID for this stat name.
    if st.map[name] then
        return st.map[name]
    end

    -- same name was seen previously, refresh it for the new map and return.
    if st.old_map and st.old_map[name] then
        local id = st.old_map[name]
        st.map[name] = id
        return id
    end

    -- iterate the ID's
    if st.next_id < STATS_MAX then
        local id = st.next_id
        st.next_id = id + 1
        mcp.add_stat(id, name)
        st.map[name] = id
        return id
    end

    if #st.freelist == 0 then
        error("max number of stat counters reached:", STATS_MAX)
    end

    -- pop a free id from the list
    -- TODO: before uncommenting this code, the proxy needs to be able to
    -- internally reset a counter when the name changes.
    --local id = table.remove(st.freelist)
    --mcp.add_stat(id, name)
    --st.map[name] = id
    --return id
end

-- _after_ pre-processing all route handlers, check if any existing stats
-- counters are unused.
-- if, across reloads, some stats counters disappear, we can reuse the IDs
-- NOTE that this is a race, we cannot reuse an ID that was freed during the
-- current load as they might be used by in-flight requests.
-- We assume:
-- 1) there's going to be some amount of time between reloads, usually more
-- than enough time for in-flight requests to finish.
-- 2) if this is ever not true, the harm is both rare and minimal.
-- 3) this is probably improvable in the future once all the pre-API2 code is
-- dropped and we can attach stats ID's to rctx's and do this
-- recycling work internally in the proxy.
function stats_turnover()
    local st = M.stats

    if st.old_map then
        for k, v in pairs(st.old_map) do
            if st.map[k] == nil then
                -- key from old map not in new map, freelist the ID
                table.insert(st.freelist, st.old_map[k])
            end
        end
    end

    st.old_map = st.map
end

--
-- Worker thread configuration functions
--

-- re-wrap the arguments to create the function generator within a worker
-- thread.
local function make_route(arg, ctx)
    dsay("generating a route:", ctx:label(), ctx:cmd())
    -- resolve the named function to a real function from global
    local f = _G[arg.f]
    -- create and return the funcgen object
    return f(arg.a, ctx)
end

-- create and return a full router object.
-- 1) walk the input route set, copying into a new map
-- 2) execute any route handlers found
-- 3) route handler resolves children into (pool/fgen) and returns fgen
-- 4) create the root route handler and return
-- NOTE: we do an unfortunate duck typing of a map entry, as metatables can't
-- cross the cross-VM barrier so we can't type the route handlers. Map entries
-- can have sub-maps and they'll both just look like tables.
-- TODO: support top level command only maps
local function make_router(set, pools)
    local map = {}
    dsay("making a new router")

    local ctx = {
        label = function(self)
            return self._label
        end,
        cmd = function(self)
            return self._cmd
        end,
        get_child = function(self, child)
            if type(child) == "string" then
                return pools[child]
            elseif type(child) == "table" then
                return make_route(child, self)
            else
                error("invalid child given to route handler")
            end
        end
    }

    if set.map then
        -- create a new map with route entries resolved.
        for mk, mv in pairs(set.map) do
            -- duck type: if this map is a route or a command map
            if mv["f"] == nil then
                dsay("command map:", mk)
                -- command map
                local cmap = {}
                for cmk, cmv in pairs(mv) do
                    ctx._label = mk
                    ctx._cmd = cmk
                    local fgen = make_route(cmv, ctx)
                    if fgen == nil then
                        error("route start handler did not return a generator")
                    end
                    cmap[cmk] = fgen
                end
                map[mk] = cmap
            else
                dsay("route:", mk)
                -- route function
                ctx._label = mk
                ctx._cmd = mcp.CMD_ANY_STORAGE
                local fgen = make_route(mv, ctx)
                if fgen == nil then
                    error("route start handler did not return a generator")
                end
                map[mk] = fgen
            end
        end
    else
        -- we're only routing based on the command, no prefix strings
        ctx._label = "default"
        for cmk, cmv in pairs(set.cmap) do
            ctx._cmd = cmk
            local fgen = make_route(cmv, ctx)
            if fgen == nil then
                error("route start handler did not return a generator")
            end
            map[cmk] = fgen
        end
    end

    -- NOTE: we're directly passing the router configuration from the user
    -- into the function, but we could use indirection here to create
    -- convenience functions, default sets, etc.
    local conf = set.conf
    if set.default then
        ctx._label = "default"
        ctx._cmd = mcp.CMD_ANY_STORAGE
        conf.default = make_route(set.default, ctx)
    end

    conf.map = map
    if set.map then
        return mcp.router_new(conf)
    else
        return conf
    end
end

--
-- ----------------
-- Loader functions
-- ----------------
--
-- Contains the top level mcp_config_pools() and mcp_config_routes() handlers
-- mcp_config_pools executes from the configuration thread
-- mcp_config_routes executes from each worker thread

function mcp_config_pools()
    dsay("mcp_config_pools: start")
    config()
    -- create all necessary pool objects and prepare the configuration for
    -- passing on to workers
    -- Step 0) update global settings if requested
    if M.c_in.settings then
        settings_parse(M.c_in.settings)
    end

    -- Step 1) create pool objects
    local pools = pools_parse(M.c_in.pools)
    -- Step 2) prepare router descriptions
    local conf = routes_parse(M.c_in.routes, pools)
    -- Step 3) Reset global configuration
    dsay("mcp_config_pools: done")
    stats_turnover()
    M = module_defaults(M)

    return conf
end

local function route_attach_map(root, tag)
    -- if we have a default, first attach everything to CMD_ANY_STORAGE
    if root.default then
        mcp.attach(mcp.CMD_ANY_STORAGE, root.default, tag)
    end

    -- now override anything more specific
    for cmd, fgen in pairs(root.map) do
        mcp.attach(cmd, fgen, tag)
    end
end

-- TODO: need a method to nil out a tag/route if unspecified. I think this
-- doesn't work from the API level.
-- NOTES:
-- 1) the "router" object is prefix/key matching only. for command maps we
-- directly set the handlers against mcp.attach()
-- 2) the system does technically support:
--    command map -> prefix map -> route|command map
--    ... but we don't allow this with this library, not right now.
-- 3) it's possible to support 2 by doing even more pre-processing, so if
-- there's demand I don't believe anything here would make it impossible.
function mcp_config_routes(c)
    local routes = c.r
    local pools = c.p
    dsay("mcp_config_routes: start")

    -- for each tagged route tree, swap pool names for pool objects, create
    -- the function generators, and the top level router object.
    for tag, set in pairs(routes) do
        dsay("building root for tag:", tag)
        local root = make_router(set, pools)
        if tag == "default" then
            dsay("attaching to proxy default tag")
            if type(root) == "userdata" then
                dsay("attaching a router")
                mcp.attach(mcp.CMD_ANY_STORAGE, root)
            else
                dsay("attaching a command map")
                route_attach_map(root)
            end
        else
            dsay("attaching to proxy for tag:", tag)
            if type(root) == "userdata" then
                dsay("attaching a router")
                mcp.attach(mcp.CMD_ANY_STORAGE, root, tag)
            else
                dsay("attaching a command map")
                route_attach_map(root, tag)
            end
        end
    end
    dsay("mcp_config_routes: done")
end

--
-- ---------------------------------------------
-- Configuration level route handler definitions
-- ---------------------------------------------
--
-- Functions run from the configuration thread which pre-parse the provided
-- route objects and do any required decoration or recursion

-- route handlers on the configuration level are descriptors.
-- actual functions need to be generated later, once passed to workers
-- 1) validate arguments if possible
-- 2) return table with construction information:
--    - function name (can't use func references since we're crossing VMs!)
--    - config settings
function route_allfastest_conf(t)
    -- TODO: validate arguments here.
    -- probably good to at least check that all children exist in the pools
    -- list.
    return { f = "route_allfastest_start", a = t }
end

function route_latest_conf(t, ctx)
    if t.stats then
        local name = ctx:label() .. "_retries"
        if t.stats_name then
            name = t.stats_name .. "_retries"
        end
        t.stats_id = stats_get_id(name)
    end
    if t.failover_count == nil then
        t.failover_count = #t.children
    end
    return { f = "route_latest_start", a = t }
end

function route_split_conf(t)
    return { f = "route_split_start", a = t }
end

-- register global wrapper functions for collecting user input
-- give the configuration a type so we can easily pick them out while walking
-- the route map later.
function register_route_handlers(t)
    for _, name in pairs(t) do
        _G["route_" .. name] = function(t)
            return setmetatable({ f = "route_" .. name .. "_conf", a = t }, RouteConf)
        end
    end
end

--
-- ---------------------------
-- Worker level Route handlers
-- ---------------------------
--

-- route process:
-- 1) create funcgen object
-- 2) replace pool names with pool objects
-- 3) return function generator
-- the label and, if known, specific sub-command are passed in so they can be
-- used for log and stats functions
-- can possibly return a command-specific optimized function

-- so many layers of generation :(
local function route_allfastest_f(rctx, arg)
    local mode = mcp.WAIT_ANY
    dsay("generating an allfastest function")
    return function(r)
        rctx:enqueue(r, arg)
        local done = rctx:wait_cond(1, mode)
        for x=1, #arg do
            local res = rctx:res_any(arg[x])
            if res ~= nil then
                return res
            end
        end
    end
end

-- copy request to all children, but return first response
function route_allfastest_start(a, ctx)
    local fgen = mcp.funcgen_new()
    dsay("starting an allfastest handler")
    local o = {}
    for _, child in pairs(a.children) do
        local c = ctx:get_child(child)
        table.insert(o, fgen:new_handle(c))
    end

    fgen:ready({ a = o, n = ctx:label(), f = route_allfastest_f })
    return fgen
end

local function route_latest_f(rctx, arg)
    local limit = arg.limit
    local count = arg.count
    local t = arg.t

    -- example of returning an optimized function based on the requirements of
    -- the function.
    -- we could either specialize the generator function returned from
    -- _start()
    -- or do it here when the slots are generated.
    if arg.stats_id then
        local s = mcp.stat
        local s_id = arg.stats_id
        dsay("making latest route with a stats counter:" .. s_id)

        return function(r)
            local retry = false
            local res = nil
            for i=1, limit do
                res = rctx:enqueue_and_wait(r, t[i])
                if retry then
                    -- increment the retries counter
                    s(s_id, 1)
                end
                if res:ok() then
                    return res
                end
                -- only increment the retries counter for an actual retry
                retry = true
            end

            -- didn't get what we want, return the final one.
            return res
        end
    else
        dsay("making latest route with no stats")
        return function(r)
            local res = nil
            for i=1, limit do
                local res = rctx:enqueue_and_wait(r, t[i])
                if res:ok() then
                    return res
                end
            end

            -- didn't get what we want, return the final one.
            return res
        end
    end
end

-- randomize the pool list
-- walk one at a time
function route_latest_start(a, ctx)
    local fgen = mcp.funcgen_new()
    local o = { t = {}, c = 0 }
    -- NOTE: if given a limit, we don't actually need handles for every pool.
    -- would be a nice small optimization to shuffle the list of children then
    -- only grab N entries.
    -- Not doing this _right now_ because I'm not confident children is an
    -- array or not.
    for _, child in pairs(a.children) do
        local c = ctx:get_child(child)
        table.insert(o.t, fgen:new_handle(c))
        o.c = o.c + 1
    end

    -- shuffle the handle list
    -- TODO: utils section with a shuffle func
    for i=#o.t, 2, -1 do
        local j = math.random(i)
        o.t[i], o.t[j] = o.t[j], o.t[i]
    end

    o.limit = a.failover_count
    o.stats_id = a.stats_id

    fgen:ready({ a = o, n = ctx:label(), f = route_latest_f })
    return fgen
end

local function route_split_f(rctx, arg)
    local a = arg.child_a
    local b = arg.child_b
    dsay("generating a split function")

    return function(r)
        rctx:enqueue(r, b)
        return rctx:enqueue_and_wait(r, a)
    end
end

-- split route
-- mostly exists just to test recursive functions
-- should add options to do things like "copy N% of traffic from A to B"
function route_split_start(a, ctx)
    local fgen = mcp.funcgen_new()
    local o = {}
    dsay("starting a split route handler")
    o.child_a = fgen:new_handle(ctx:get_child(a.child_a))
    o.child_b = fgen:new_handle(ctx:get_child(a.child_b))
    fgen:ready({ a = o, n = ctx:label(), f = route_split_f })

    return fgen
end

-- TODO: failover route

register_route_handlers({
    "latest",
    "allfastest",
    "split",
})
