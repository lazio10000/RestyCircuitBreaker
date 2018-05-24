# RestyCircuitBreaker openresty断路器 #

## 简介 ##

由于某些场景下服务提供方和调用方都无法做到可用性，当系统远程调用时，可能会因为某些接口变慢导致调用方大量HTTP连接被阻塞而引发雪崩。

解决思路如下：

- 服务提供方实现接口快速失败，当处理时间达到一定阈值时，直接返回失败。需要服务提供方配合改造。
- 服务提供方在反向代理层增加proxy_timeout配置。如果配置了upstream max_fails，可能会导致所有的服务实例都被踢掉。而不配置max_fails则出问题的时间段内这个接口每次调用都会在proxy_timeout时间才能返回超时。
- 服务接入方调用远程接口失败时触发熔断，一定时间内不在调用远程服务。需要服务接入方配合改造。

综上，这个问题服务提供方和接入方分别做到快速失败和熔断降级，就可以很好的决解。但是某些业务场景，服务提供方和接口方都无法改进时，我们只好在反向代理层想办法。

## 思路 ##

在nginx中利用lua脚本实现断路器功能。

- 定义ngx.shared.DICT字典，用于记录每个接口的熔断状态和超时次数  

- 在init_worker_by_lua阶段定义定时任务，用户清空超时次数和对已经打开一段时间的断路器设为半开

![](https://i.imgur.com/Eyc3Vj9.png)

- 在access_by_lua阶段执行判断，判断当前请求是否熔断。已熔断则直接返回失败。

- 在log_by_lua阶段判断请求是否超时，如超时则记录超时次数并更新熔断器状态。

![](https://i.imgur.com/djnz1R9.png)

## nginx 配置说明 ##
- RestyCircuitBreaker.lua 放至lua脚本文件夹
- http段定义字典：  
   
	    lua_shared_dict resty_circuit_breaker_dict 2M;  
	    lua_shared_dict resty_circuit_breake_timeout_dict 10M;      
- http段 执行init_by_lua脚本：

		restyCircuitBreaker = require("RestyCircuitBreaker").init("pdc")
- http段 执行init_worker_by_lua脚本：
 
		restyCircuitBreaker:set_background()
- server或者location段  执行access_by_lua脚本: 

     	restyCircuitBreaker:run()
- server或者location段  执行access_by_lua脚本：

		restyCircuitBreaker:set_bucket()

- 通过prometheus查看断路器状态  
- 
		# HELP circuit_status 断路器状态
		# TYPE circuit_status gauge
		circuit_status{system="pdc",url="/marketing/get_info"} 2
		# HELP circuit_time 断路打开时间
		# TYPE circuit_time counter
		circuit_time{system="pdc",url="/marketing/get_info"} 10