package bot

import (
	"EverythingSuckz/fsb/config"
	"errors"

	"github.com/celestix/gotgproto"
	"github.com/celestix/gotgproto/sessionMaker"
	"github.com/gotd/td/tg"
	"go.uber.org/zap"
)

type UserBotStruct struct {
	log    *zap.Logger
	client *gotgproto.Client
}

var UserBot *UserBotStruct = &UserBotStruct{}

func StartUserBot(l *zap.Logger) {
	log := l.Named("USERBOT")
	if config.ValueOf.UserSession == "" {
		log.Warn("用户会话为空")
		return
	}
	log.Sugar().Infoln("正在启动用户机器人")
	client, err := gotgproto.NewClient(
		int(config.ValueOf.ApiID),
		config.ValueOf.ApiHash,
		gotgproto.ClientTypePhone(""),
		&gotgproto.ClientOpts{
			Session:          sessionMaker.PyrogramSession(config.ValueOf.UserSession),
			DisableCopyright: true,
		},
	)
	if err != nil {
		log.Error("启动用户机器人失败", zap.Error(err))
		return
	}
	UserBot.log = log
	UserBot.client = client
	log.Info("用户机器人已启动", zap.String("username", client.Self.Username), zap.String("FirstName", client.Self.FirstName), zap.String("LastName", client.Self.LastName))
	if err := UserBot.AddBotsAsAdmins(); err != nil {
		log.Error("添加机器人管理员失败", zap.Error(err))
		return
	}
}

func (u *UserBotStruct) AddBotsAsAdmins() error {
	u.log.Info("正在准备添加机器人管理员")
	ctx := u.client.CreateContext()
	channel := config.ValueOf.LogChannelID
	channelInfos, err := u.client.API().ChannelsGetChannels(
		ctx,
		[]tg.InputChannelClass{
			&tg.InputChannel{
				ChannelID: channel,
			},
		},
	)
	if err != nil {
		u.log.Error("获取频道信息失败", zap.Error(err))
		return errors.New("获取频道信息失败")
	}
	if len(channelInfos.GetChats()) == 0 {
		return errors.New("未找到频道")
	}
	inputChannel := channelInfos.GetChats()[0].(*tg.Channel).AsInput()
	currentAdmins := []int64{}
	admins, err := u.client.API().ChannelsGetParticipants(ctx, &tg.ChannelsGetParticipantsRequest{
		Channel: inputChannel,
		Filter:  &tg.ChannelParticipantsAdmins{},
		Offset:  0,
		Limit:   100,
	})
	if err != nil {
		u.log.Error("获取管理员列表失败", zap.Error(err))
		return err
	}
	for _, admin := range admins.(*tg.ChannelsChannelParticipants).Participants {
		if user, ok := admin.(*tg.ChannelParticipantAdmin); ok {
			currentAdmins = append(currentAdmins, user.UserID)
		}
	}
	for _, bot := range Workers.Bots {
		isAdmin := false
		for _, admin := range currentAdmins {
			if admin == bot.Self.ID {
				u.log.Sugar().Infof("机器人 @%s 已经是管理员", bot.Self.Username)
				isAdmin = true
				continue
			}
		}
		if isAdmin {
			continue
		}
		botInfo, err := ctx.ResolveUsername(bot.Self.Username)
		if err != nil {
			u.log.Warn(err.Error())
		}
		_, err = u.client.API().ChannelsEditAdmin(
			u.client.CreateContext().Context,
			&tg.ChannelsEditAdminRequest{
				Channel: inputChannel,
				UserID:  botInfo.GetInputUser(),
				AdminRights: tg.ChatAdminRights{
					PostMessages: true,
				},
				Rank: "admin",
			},
		)
		if err != nil {
			u.log.Sugar().Warnf("添加 @%s 为管理员失败", bot.Self.Username)
			u.log.Warn(err.Error())
		}
		u.log.Sugar().Infof("已添加 @%s 为管理员", bot.Self.Username)
	}
	return nil
}
