package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"go.mau.fi/whatsmeow"
	"strings"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
)

// mediaRef is everything needed to download an attachment later without
// keeping the protobuf around.
type mediaRef struct {
	DirectPath string `json:"p"`
	MediaKey   string `json:"k"`
	FileSHA    string `json:"h"`
	FileEncSHA string `json:"e"`
	Type       string `json:"t"` // image | video | audio | document
	Length     uint64 `json:"l"`
	// Thumbnail as a separate small download (WhatsApp no longer always inlines JPEGThumbnail).
	ThumbPath   string `json:"thumb_path,omitempty"`
	ThumbSHA    string `json:"ts,omitempty"`
	ThumbEncSHA string `json:"tes,omitempty"`
}

type downloadable interface {
	GetDirectPath() string
	GetMediaKey() []byte
	GetFileSHA256() []byte
	GetFileEncSHA256() []byte
	GetFileLength() uint64
}

func refFor(d downloadable, typ string) string {
	if d.GetDirectPath() == "" || len(d.GetMediaKey()) == 0 {
		return ""
	}
	ref := mediaRef{
		DirectPath: d.GetDirectPath(),
		MediaKey:   base64.StdEncoding.EncodeToString(d.GetMediaKey()),
		FileSHA:    base64.StdEncoding.EncodeToString(d.GetFileSHA256()),
		FileEncSHA: base64.StdEncoding.EncodeToString(d.GetFileEncSHA256()),
		Type:       typ,
		Length:     d.GetFileLength(),
	}
	if t, ok := d.(whatsmeow.DownloadableThumbnail); ok && t.GetThumbnailDirectPath() != "" {
		ref.ThumbPath = t.GetThumbnailDirectPath()
		ref.ThumbSHA = base64.StdEncoding.EncodeToString(t.GetThumbnailSHA256())
		ref.ThumbEncSHA = base64.StdEncoding.EncodeToString(t.GetThumbnailEncSHA256())
	}
	b, _ := json.Marshal(ref)
	return string(b)
}

// content fills the display fields of a row from a decoded message.
// It returns false for messages with nothing to show (key distribution,
// protocol chatter, etc.).
func (a *App) content(m *waE2E.Message, r *msgRow) bool {
	if m == nil {
		return false
	}
	var ci *waE2E.ContextInfo
	switch {
	case m.GetConversation() != "":
		r.Kind, r.Text = KText, m.GetConversation()
	case m.GetExtendedTextMessage() != nil:
		t := m.GetExtendedTextMessage()
		r.Kind, r.Text, ci = KText, t.GetText(), t.GetContextInfo()
		if t.GetTitle() != "" || len(t.GetJPEGThumbnail()) > 0 {
			r.LinkURL, r.LinkTitle, r.LinkDesc = t.GetMatchedText(), t.GetTitle(), t.GetDescription()
			r.Thumb, r.Width, r.Height = t.GetJPEGThumbnail(), int(t.GetThumbnailWidth()), int(t.GetThumbnailHeight())
		}
	case m.GetImageMessage() != nil:
		x := m.GetImageMessage()
		r.Kind, r.Text, ci = KImage, x.GetCaption(), x.GetContextInfo()
		r.Mime, r.Width, r.Height, r.Thumb = x.GetMimetype(), int(x.GetWidth()), int(x.GetHeight()), x.GetJPEGThumbnail()
		r.FileSize, r.Media = int64(x.GetFileLength()), refFor(x, "image")
	case m.GetVideoMessage() != nil:
		x := m.GetVideoMessage()
		r.Kind, r.Text, ci = KVideo, x.GetCaption(), x.GetContextInfo()
		r.Mime, r.Width, r.Height, r.Thumb = x.GetMimetype(), int(x.GetWidth()), int(x.GetHeight()), x.GetJPEGThumbnail()
		r.Seconds, r.FileSize, r.Media = int(x.GetSeconds()), int64(x.GetFileLength()), refFor(x, "video")
		if x.GetGifPlayback() {
			r.FileName = "GIF"
			if a := gifSource(x.GetGifAttribution()); a != "" {
				r.Extra = jsonString(map[string]string{"gif": a})
			}
		}
	case m.GetAudioMessage() != nil:
		x := m.GetAudioMessage()
		r.Kind, ci = KAudio, x.GetContextInfo()
		if x.GetPTT() {
			r.Kind = KVoice
		}
		r.Mime, r.Seconds, r.FileSize, r.Media = x.GetMimetype(), int(x.GetSeconds()), int64(x.GetFileLength()), refFor(x, "audio")
		r.Waveform = x.GetWaveform()
	case m.GetDocumentMessage() != nil:
		x := m.GetDocumentMessage()
		r.Kind, r.Text, ci = KDocument, x.GetCaption(), x.GetContextInfo()
		r.Mime, r.FileName, r.Thumb = x.GetMimetype(), x.GetFileName(), x.GetJPEGThumbnail()
		if r.FileName == "" {
			r.FileName = x.GetTitle()
		}
		r.FileSize, r.Media = int64(x.GetFileLength()), refFor(x, "document")
	case m.GetStickerMessage() != nil:
		x := m.GetStickerMessage()
		r.Kind, ci = KSticker, x.GetContextInfo()
		r.Mime, r.Width, r.Height = x.GetMimetype(), int(x.GetWidth()), int(x.GetHeight())
		r.FileSize, r.Media = int64(x.GetFileLength()), refFor(x, "image")
	case m.GetLocationMessage() != nil:
		x := m.GetLocationMessage()
		r.Kind, ci = KLocation, x.GetContextInfo()
		r.Text = strings.TrimSpace(x.GetName() + "\n" + x.GetAddress())
		r.FileName = fmt.Sprintf("%f,%f", x.GetDegreesLatitude(), x.GetDegreesLongitude())
		r.Thumb = x.GetJPEGThumbnail()
	case m.GetLiveLocationMessage() != nil:
		x := m.GetLiveLocationMessage()
		r.Kind, ci = KLocation, x.GetContextInfo()
		r.Text = "Live location"
		r.FileName = fmt.Sprintf("%f,%f", x.GetDegreesLatitude(), x.GetDegreesLongitude())
	case m.GetContactMessage() != nil:
		x := m.GetContactMessage()
		r.Kind, r.Text, ci = KContact, x.GetDisplayName(), x.GetContextInfo()
		r.Extra = jsonString(contactExtra{Cards: []contactCard{parseVCard(x.GetDisplayName(), x.GetVcard())}})
	case m.GetContactsArrayMessage() != nil:
		x := m.GetContactsArrayMessage()
		r.Kind, r.Text, ci = KContact, fmt.Sprintf("%d contacts", len(x.GetContacts())), x.GetContextInfo()
		var cards []contactCard
		for _, c := range x.GetContacts() {
			cards = append(cards, parseVCard(c.GetDisplayName(), c.GetVcard()))
		}
		r.Extra = jsonString(contactExtra{Cards: cards})
	case pollCreation(m) != nil:
		x := pollCreation(m)
		r.Kind, r.Text, ci = KPoll, x.GetName(), x.GetContextInfo()
		opts := make([]string, 0, len(x.GetOptions()))
		for _, o := range x.GetOptions() {
			opts = append(opts, o.GetOptionName())
		}
		r.Extra = jsonString(pollExtra{Options: opts, Multi: x.GetSelectableOptionsCount() != 1})
	case m.GetEventMessage() != nil:
		x := m.GetEventMessage()
		r.Kind, r.Text, ci = KEvent, x.GetName(), x.GetContextInfo()
		r.Extra = jsonString(eventFrom(x))
	case m.GetGroupInviteMessage() != nil:
		x := m.GetGroupInviteMessage()
		r.Kind, r.Text, ci = KText, "Group invite: "+x.GetGroupName(), x.GetContextInfo()
	case m.GetPtvMessage() != nil:
		x := m.GetPtvMessage()
		r.Kind, ci = KVideo, x.GetContextInfo()
		r.Mime, r.Width, r.Height, r.Thumb = x.GetMimetype(), int(x.GetWidth()), int(x.GetHeight()), x.GetJPEGThumbnail()
		r.Seconds, r.FileSize, r.Media = int(x.GetSeconds()), int64(x.GetFileLength()), refFor(x, "video")
	case m.GetButtonsMessage() != nil:
		r.Kind, r.Text = KText, m.GetButtonsMessage().GetContentText()
	case m.GetTemplateMessage() != nil:
		r.Kind, r.Text = KText, m.GetTemplateMessage().GetHydratedTemplate().GetHydratedContentText()
	case m.GetListMessage() != nil:
		r.Kind, r.Text = KText, m.GetListMessage().GetDescription()
	case m.GetInteractiveMessage() != nil:
		r.Kind, r.Text = KText, m.GetInteractiveMessage().GetBody().GetText()
	case m.GetViewOnceMessage() != nil || m.GetViewOnceMessageV2() != nil:
		r.Kind, r.Text = KUnsupported, "View once message. Open it on your phone."
	case m.GetCall() != nil:
		r.Kind, r.Text = KUnsupported, "Call"
	default:
		return false
	}
	if ci != nil {
		a.applyContext(ci, r)
	}
	return true
}

// applyContext pulls reply-quote and @mention info out of ContextInfo.
func (a *App) applyContext(ci *waE2E.ContextInfo, r *msgRow) {
	if id := ci.GetStanzaID(); id != "" && ci.GetQuotedMessage() != nil {
		r.QuoteID = id
		if p, err := types.ParseJID(ci.GetParticipant()); err == nil {
			r.QuoteSender = a.canon(p).String()
		}
		var q msgRow
		if a.content(ci.GetQuotedMessage(), &q) {
			r.QuoteKind = q.Kind
			r.QuoteText = q.Text
			if r.QuoteText == "" {
				r.QuoteText = q.FileName
			}
		}
	}
	if r.Text != "" {
		for _, mj := range ci.GetMentionedJID() {
			j, err := types.ParseJID(mj)
			if err != nil {
				continue
			}
			if name := a.nameFor(a.canon(j)); name != "" {
				r.Text = strings.ReplaceAll(r.Text, "@"+j.User, "@"+name)
			}
		}
	}
}

// previewText is the one-line summary used in notifications.
func previewText(r *msgRow) string {
	labels := map[int]string{
		KImage: "📷 Photo", KVideo: "🎥 Video", KAudio: "🎵 Audio", KVoice: "🎤 Voice message",
		KDocument: "📄 Document", KSticker: "Sticker", KLocation: "📍 Location", KContact: "👤 Contact",
		KPoll: "📊 Poll", KEvent: "📅 Event",
	}
	if r.Kind == KText || r.Kind == KUnsupported {
		return r.Text
	}
	l := labels[r.Kind]
	if r.Text != "" {
		return l + ": " + strings.SplitN(r.Text, "\n", 2)[0]
	}
	if r.Kind == KDocument && r.FileName != "" {
		return "📄 " + r.FileName
	}
	return l
}
