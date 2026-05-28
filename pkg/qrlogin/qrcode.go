// This file is a part of EverythingSuckz/TG-FileStreamBot
// And is licenced under the Affero General Public License.
// Any distributions of this code MUST be accompanied by a copy of the AGPL
// with proper attribution to the original author(s).

package qrlogin

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/gotd/td/session"
	"github.com/gotd/td/telegram"
	"github.com/gotd/td/telegram/auth/qrlogin"
	"github.com/gotd/td/tg"
	"github.com/gotd/td/tgerr"
	"github.com/mdp/qrterminal"
)

type CustomWriter struct {
	LineLength int
}

func (w *CustomWriter) Write(p []byte) (n int, err error) {
	for _, c := range p {
		if c == '\n' {
			w.LineLength++
		}
	}
	return os.Stdout.Write(p)
}

func printQrCode(data string, writer *CustomWriter) {
	qrterminal.GenerateHalfBlock(data, qrterminal.L, writer)
}

func clearQrCode(writer *CustomWriter) {
	for i := 0; i < writer.LineLength; i++ {
		fmt.Printf("\033[F\033[K")
	}
	writer.LineLength = 0
}

func GenerateQRSession(apiId int, apiHash string) error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	fmt.Println("正在生成二维码会话...")
	reader := bufio.NewReader(os.Stdin)
	dispatcher := tg.NewUpdateDispatcher()
	loggedIn := qrlogin.OnLoginToken(dispatcher)
	sessionStorage := &session.StorageMemory{}
	client := telegram.NewClient(apiId, apiHash, telegram.Options{
		UpdateHandler:  dispatcher,
		SessionStorage: sessionStorage,
		Device: telegram.DeviceConfig{
			DeviceModel:   "Pyrogram",
			SystemVersion: runtime.GOOS,
			AppVersion:    "2.0",
		},
	})
	var stringSession string
	qrWriter := &CustomWriter{}
	tickerCtx, cancelTicker := context.WithCancel(context.Background())
	err := client.Run(ctx, func(ctx context.Context) error {
		authorization, err := client.QR().Auth(ctx, loggedIn, func(ctx context.Context, token qrlogin.Token) error {
			if qrWriter.LineLength == 0 {
				fmt.Printf("\033[F\033[K")
			}
			clearQrCode(qrWriter)
			printQrCode(token.URL(), qrWriter)
			qrWriter.Write([]byte("\n要登录，请打开 Telegram 应用，进入 设置 > 设备 > 扫描二维码，然后扫描上方的二维码。\n"))
			go func(ctx context.Context) {
				ticker := time.NewTicker(1 * time.Second)
				defer ticker.Stop()
				for {
					select {
					case <-ctx.Done():
						return
					case <-ticker.C:
						expiresIn := time.Until(token.Expires())
						if expiresIn <= 0 {
							return
						}
						fmt.Printf("\r此二维码将在 %s 后过期", expiresIn.Truncate(time.Second))
					}
				}
			}(tickerCtx)
			return nil
		})
		if err != nil {
			if tgerr.Is(err, "SESSION_PASSWORD_NEEDED") {
				cancelTicker()
				fmt.Println("\n需要两步验证密码，请在下方输入: ")
				passkey, _ := reader.ReadString('\n')
				strippedPasskey := strings.TrimSpace(passkey)
				authorization, err = client.Auth().Password(ctx, strippedPasskey)
				if err != nil {
					if err.Error() == "invalid password" {
						fmt.Println("密码无效，请重试。")
					}
					fmt.Println("登录时出错: ", err)
					return nil
				}
			}
		}
		if authorization == nil {
			cancel()
			return errors.New("authorization is nil")
		}
		user, err := client.Self(ctx)
		if err != nil {
			return err
		}
		if user.Username == "" {
			fmt.Println("已登录为 ", user.FirstName, user.LastName)
		} else {
			fmt.Println("已登录为 @", user.Username)
		}
		res, _ := sessionStorage.LoadSession(ctx)
		type jsonDataStruct struct {
			Version int
			Data    session.Data
		}
		var jsonData jsonDataStruct
		json.Unmarshal(res, &jsonData)
		stringSession, err = EncodeToPyrogramSession(&jsonData.Data, int32(apiId))
		if err != nil {
			return err
		}
		fmt.Println("您的 Pyrogram 会话字符串:", stringSession)
		client.API().MessagesSendMessage(
			ctx,
			&tg.MessagesSendMessageRequest{
				NoWebpage: true,
				Peer:      &tg.InputPeerSelf{},
				Message:   "您的 Pyrogram 会话字符串: " + stringSession,
			},
		)
		return nil
	})
	if err != nil {
		return err
	}
	return nil
}
