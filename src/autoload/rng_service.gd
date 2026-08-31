extends Node
## RngStreams 的持有者 —— 架构纪律 1（§12.1）
##
## ⚠️ src/core/ 【禁止】引用本文件。
##   core 通过构造参数接收 RngStreams 实例（注入），不主动去找 autoload。
##   这样 battle_sim 与单测可以自己 new 一个 RngStreams，无需 mock autoload。

var streams: RngStreams


func _ready() -> void:
	# 默认用时间做 seed。正式开局时由 RunManager 用显式 seed 重建。
	# ⚠️ 这里用 Time 是允许的 —— 它在 autoload（表现层）而非 core 里，
	#    且只用于"生成一个新局的 seed"，不参与任何游戏逻辑判定。
	reseed(Time.get_unix_time_from_system() as int)


func reseed(master_seed: int) -> void:
	streams = RngStreams.new(master_seed)


func get_streams() -> RngStreams:
	if streams == null:
		reseed(0)
	return streams
