-- Openresty Circuit Breaker
-- lua-nginx-module 版本 >= v0.9.17
-- TODO:  降级，失败率
-- dongxiang 2018/5/21
local RestyCircuitBreaker={}
RestyCircuitBreaker.__index = RestyCircuitBreaker  
--接口超时时间，毫秒
local INTERRUPT_ON_TIMEOUT_MS = 5000
--超时个数阈值，15秒内大于此阈值熔断
local TIMEOUT_TIMES = 20
--熔断时间，秒 
local CIRCUIT_TIME = 5
--熔断超时时间,秒
local CIRCUIT_TIMEOUT = 15 
local CIRCUIT_STATUS_CLOSE = 0 
local CIRCUIT_STATUS_OPEN = 1 
local CIRCUIT_STATUS_HALF = 2  
local CIRCUIT_STATUS_CHECK = 3  
local DELAY = 1  
 
-- 初始化   
function RestyCircuitBreaker.init(system) 
    local self = setmetatable({}, RestyCircuitBreaker)
    self.circuit_dict = ngx.shared["resty_circuit_breaker_dict"] 
    self.timeout_dict = ngx.shared["resty_circuit_breake_timeout_dict"] 
    self.circuit_list = {} 
    self.bucket_lifecycle = 15     
    self.system = system  
    -- 定义prometheus指标
    self.circuit_status = prometheus:gauge("circuit_status", "断路器状态，0 CLOSE,1 OPEN,2 HALF,3 CHECK", {"system","url"}) 
    self.circuit_times = prometheus:counter("circuit_times", "熔断次数", {"system","url"}) 
    return self 
end 
 
-- 设定定时任务
function RestyCircuitBreaker:set_background()   
    local ok, err = ngx.timer.at(DELAY, RestyCircuitBreaker.bucket_handler,self)
    if not ok then
        ngx.log(ngx.ERR, "failed to create timer: ", err)
        return
    end
end

-- 记录超时时间
function RestyCircuitBreaker:set_bucket(request_url,http_request_time) 
    if request_url == nil then
        request_url = ngx.var.request_uri:gsub("?.*", ""):gsub("/[0-9]*$", "")     
    end
    if http_request_time == nil then
        http_request_time = tonumber(ngx.now() - ngx.req.start_time())*1000
    end
    local circuit_key = "Circuit_"..request_url 
    local circuit_status = self.circuit_dict:get(circuit_key) 
    if circuit_status == CIRCUIT_STATUS_CHECK then
        if http_request_time < INTERRUPT_ON_TIMEOUT_MS then
            ngx.log(ngx.NOTICE, circuit_key .. "check ---> close")
            self.circuit_dict:delete(circuit_key)   
            self.circuit_status:set(CIRCUIT_STATUS_CLOSE,{self.system,request_url})
            return
        else 
            ngx.log(ngx.NOTICE, circuit_key .."check ---> open")
            self.circuit_dict:set(circuit_key, CIRCUIT_STATUS_OPEN,CIRCUIT_TIME)   
            self.circuit_list[circuit_key] = CIRCUIT_TIME
            self.circuit_status:set(CIRCUIT_STATUS_OPEN,{self.system,request_url})
            self.circuit_times:inc(1,{self.system,request_url})
            return
        end
    end
    -- timeout
    if http_request_time >= INTERRUPT_ON_TIMEOUT_MS then 
        local timeout_key = "TimeOut_"..request_url 
        local timeout_times, err = self.timeout_dict:incr(timeout_key, 1)
        if err == "not found" then
            self.timeout_dict:set(timeout_key, 1, self.bucket_lifecycle) 
            timeout_times = 1
        end 
        if timeout_times >= TIMEOUT_TIMES and circuit_status ~= CIRCUIT_STATUS_OPEN then    
          ngx.log(ngx.NOTICE, "close/half ---> open")
          self.circuit_dict:set(circuit_key, CIRCUIT_STATUS_OPEN,CIRCUIT_TIME)   
          self.circuit_list[circuit_key] = CIRCUIT_TIME
          self.circuit_status:set(CIRCUIT_STATUS_OPEN,{self.system,request_url})
          self.circuit_times:inc(1,{self.system,request_url})
          return
        end  
    end  
end

-- 定时任务
function RestyCircuitBreaker.bucket_handler(premature, self)  
    if self.bucket_lifecycle == 0 then
        self.bucket_lifecycle = 15
    else 
        self.bucket_lifecycle = self.bucket_lifecycle - 1
    end 
    if self.bucket_lifecycle == 0 then  
        self.timeout_dict:flush_all()
    end  
    for key,value in pairs(self.circuit_list) do 
        if value ~= nil then
            if value == 1 then 
                ngx.log(ngx.NOTICE, "open ---> half "..key)
                self.circuit_dict:set(key, CIRCUIT_STATUS_HALF,CIRCUIT_TIMEOUT) 
                self.circuit_list[key] = nil
                self.circuit_status:set(CIRCUIT_STATUS_HALF,{self.system,string.sub(key,9)})
            else 
                self.circuit_list[key] = value - 1
            end   
        end 
    end 
    local ok, err = ngx.timer.at(DELAY, RestyCircuitBreaker.bucket_handler,self)
    if not ok then
        ngx.log(ngx.ERR, "failed to create the timer: ", err) 
    end 
end

-- 
function RestyCircuitBreaker:run(request_url)
    if request_url == nil then
        request_url = ngx.var.request_uri:gsub("?.*", ""):gsub("/[0-9]*$", "")     
    end 
    local circuit_key = "Circuit_"..request_url 
    local circuit_status = self.circuit_dict:get(circuit_key)
    if circuit_status == CIRCUIT_STATUS_OPEN then 
        -- return 503 
        ngx.header.content_type = "application/json"
        ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE   
        ngx.exit(ngx.status) 
        return
    elseif circuit_status == CIRCUIT_STATUS_HALF then 
        ngx.log(ngx.NOTICE, "half ---> check ")
        self.circuit_dict:set(circuit_key, CIRCUIT_STATUS_CHECK, CIRCUIT_TIMEOUT)  
        self.circuit_status:set(CIRCUIT_STATUS_CHECK,{self.system,request_url})
        return 
    end
end 
return RestyCircuitBreaker