package main

import (
	"EverythingSuckz/fsb/config"
	"EverythingSuckz/fsb/internal/bot"
	"EverythingSuckz/fsb/internal/cache"
	"EverythingSuckz/fsb/internal/routes"
	"EverythingSuckz/fsb/internal/types"
	"EverythingSuckz/fsb/internal/utils"
	"fmt"
	"net/http"
	"time"

	"github.com/spf13/cobra"

	"github.com/gin-gonic/gin"
	"go.uber.org/zap"
)

var runCmd = &cobra.Command{
	Use:                "run",
	Short:              "使用给定配置运行机器人。",
	DisableSuggestions: false,
	Run:                runApp,
}

var startTime time.Time = time.Now()

func runApp(cmd *cobra.Command, args []string) {
	// initialize logger early so config loading is logged to file
	utils.InitLogger(false)
	config.Load(utils.Logger, cmd)
	// reinitialize with correct dev mode
	utils.InitLogger(config.ValueOf.Dev)
	log := utils.Logger
	mainLogger := log.Named("Main")
	mainLogger.Info("正在启动服务器")
	router := getRouter(log)

	mainBot, err := bot.StartClient(log)
	if err != nil {
		log.Sugar().Fatalf("启动主机器人失败: %v", err)
	}
	cache.InitCache(log)
	workers, err := bot.StartWorkers(log)
	if err != nil {
		log.Sugar().Fatalf("启动工作机器人失败: %v", err)
	}
	workers.AddDefaultClient(mainBot, mainBot.Self)
	bot.StartUserBot(log)
	mainLogger.Info("服务器已启动", zap.Int("端口", config.ValueOf.Port))
	mainLogger.Info("文件直链机器人", zap.String("版本", versionString))
	mainLogger.Sugar().Infof("服务器运行于 %s", config.ValueOf.Host)
	err = router.Run(fmt.Sprintf(":%d", config.ValueOf.Port))
	if err != nil {
		mainLogger.Sugar().Fatalf("服务器启动失败: %v", err)
	}
}

func getRouter(log *zap.Logger) *gin.Engine {
	if config.ValueOf.Dev {
		gin.SetMode(gin.DebugMode)
	} else {
		gin.SetMode(gin.ReleaseMode)
	}
	router := gin.Default()
	router.Use(gin.ErrorLogger())
	router.GET("/", func(ctx *gin.Context) {
		ctx.JSON(http.StatusOK, types.RootResponse{
			Message: "服务正在运行。<br>感谢使用文件直链机器人！如果满意欢迎前往 Github 给我们点个 Star！原作者仓库：https://github.com/EverythingSuckz/TG-FileStreamBot 。感谢所有贡献者！",
			Ok:      true,
			Uptime:  utils.TimeFormat(uint64(time.Since(startTime).Seconds())),
			Version: versionString,
		})
	})
	routes.Load(log, router)
	return router
}
