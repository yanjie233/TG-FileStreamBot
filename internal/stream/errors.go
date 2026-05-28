package stream

import "errors"

var (
	// 客户端在流完成前断开连接
	ErrStreamClosed = errors.New("客户端已断开连接")

	// 数据块获取超时
	ErrBlockTimeout = errors.New("数据块获取超时")

	// 所有重试尝试均失败
	ErrMaxRetriesExceeded = errors.New("已超过最大重试次数")

	// 管道已关闭且所有数据已消费
	ErrPipeDrained = errors.New("管道已排空")
)
