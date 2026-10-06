# Mattermost から取り込んだあと、最初のチャンネルを Zulip の既定に合わせる(2026-10-05 に決めた)。
# README.md の「3. Mattermost のデータを取り込む」の最後に 1 回流す。**何度流しても同じ結果になる。**
#
#   kubectl -n zulip exec -i zulip-0 -c zulip -- runuser -u zulip -- \
#     /home/zulip/deployments/current/manage.py shell < apps/zulip/post-import.py
#
# Mattermost の既定の 2 つ(Town Square / Off-Topic)は、どちらも投稿が参加の 1 件だけだった
# (中身は notify-* にある)。名前を Mattermost に従わせず、Zulip 12.3 が新しい組織に作る 3 つに揃える:
#
#   general  組織全体の会話。新しいチャンネルのお知らせと Zulip の更新のお知らせもここ ← Town Square
#   sandbox  試し書き                                                          ← Off-Topic
#   Zulip    Zulip の使い方の質問と話し合い                                        (新しく作る)
#
# 名前は Zulip の既定どおり英語のまま(Zulip の日本語訳でも名前は訳さない)。説明は Zulip の日本語訳と同じ文。
# 3 つとも「新しく入った人が自動で参加する」チャンネルにする(Zulip の既定と同じ)。

from django.db import transaction

from zerver.actions.default_streams import do_add_default_stream
from zerver.actions.realm_settings import (
    do_set_realm_new_stream_announcements_stream,
    do_set_realm_zulip_update_announcements_stream,
)
from zerver.actions.streams import do_change_stream_description, do_rename_stream
from zerver.lib.streams import ensure_stream
from zerver.models import Stream, UserProfile
from zerver.models.realms import get_realm

realm = get_realm("")  # ルートドメイン(z.doany.io)の組織
owner = UserProfile.objects.get(realm=realm, delivery_email="info@doany.io")

# (Mattermost での名前, Zulip の名前, 説明)。取り込みが表示名と内部名のどちらで移すかに
# 左右されないよう、両方で探す
CHANNELS = [
    (("Town Square", "town-square"), "general", "チーム全体での会話に"),
    (("Off-Topic", "off-topic"), "sandbox", "ここで Zulip を試してみましょう。 :test_tube:"),
    ((), "Zulip", "Zulip の使用方法に関する質問や議論。"),
]


def find(name: str) -> Stream | None:
    return Stream.objects.filter(realm=realm, name__iexact=name).first()


with transaction.atomic():
    made = {}
    for old, new, description in CHANNELS:
        stream = find(new)
        for name in old if stream is None else ():
            stream = find(name)
            if stream is not None:
                do_rename_stream(stream, new, owner)
                print(f"改名: {name} → {new}")
                break
        if stream is None:
            # 上の find() で無いと分かっているので、ここで必ず新しく作られる
            stream = ensure_stream(realm, new, stream_description=description, acting_user=owner)
            print(f"作成: {new}")
        if stream.description != description:
            do_change_stream_description(stream, description, acting_user=owner)
        do_add_default_stream(stream)
        made[new] = stream

    general = made["general"]
    do_set_realm_new_stream_announcements_stream(realm, general, general.id, acting_user=owner)
    do_set_realm_zulip_update_announcements_stream(realm, general, general.id, acting_user=owner)

print("最初のチャンネル:", ", ".join(made))
