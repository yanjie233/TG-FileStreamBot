package main

import (
	"fmt"

	"EverythingSuckz/fsb/pkg/qrlogin"

	"github.com/spf13/cobra"
)

var sessionCmd = &cobra.Command{
	Use:                "session",
	Short:              "生成字符串会话。",
	DisableSuggestions: false,
	Run:                generateSession,
}

func init() {
	sessionCmd.Flags().StringP("login-type", "T", "qr", "登录方式，可选 'qr' 或 'phone'")
	sessionCmd.Flags().Int32P("api-id", "I", 0, "用于会话的 API ID（必填）。")
	sessionCmd.Flags().StringP("api-hash", "H", "", "用于会话的 API Hash（必填）。")
	sessionCmd.MarkFlagRequired("api-id")
	sessionCmd.MarkFlagRequired("api-hash")
}

func generateSession(cmd *cobra.Command, args []string) {
	loginType, _ := cmd.Flags().GetString("login-type")
	apiId, _ := cmd.Flags().GetInt32("api-id")
	apiHash, _ := cmd.Flags().GetString("api-hash")
	if loginType == "qr" {
		qrlogin.GenerateQRSession(int(apiId), apiHash)
	} else if loginType == "phone" {
		generatePhoneSession()
	} else {
		fmt.Println("无效的登录类型，请使用 'qr' 或 'phone'")
	}
}

func generatePhoneSession() {
	fmt.Println("手机号登录会话功能暂未实现。")
}
