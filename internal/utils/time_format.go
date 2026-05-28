package utils

import (
	"fmt"
	"math/bits"
)

func TimeFormat(seconds uint64) (timeStr string) {
	hours, remainder := bits.Div64(0, seconds, 3600)
	minutes, seconds := bits.Div64(0, remainder, 60)
	days, hours := bits.Div64(0, hours, 24)
	timeStr = ""
	if days > 0 {
		timeStr += fmt.Sprintf("%d 天 ", days)
	}
	if hours > 0 {
		timeStr += fmt.Sprintf("%d 小时 ", hours)
	}
	if minutes > 0 {
		timeStr += fmt.Sprintf("%d 分钟 ", minutes)
	}
	if seconds > 0 {
		timeStr += fmt.Sprintf("%d 秒", seconds)
	}
	return timeStr
}
