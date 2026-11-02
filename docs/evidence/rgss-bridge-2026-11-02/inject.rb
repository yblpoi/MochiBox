# -*- coding: utf-8 -*-
# 真机证据用注入器：在同一轮游戏里把同一行文本显示两次。
# 不是产品代码；只通过 mkxp.json 的 preloadScript 进入测试进程。
LOG = ENV['MOCHI_INJECT_LOG'] || '/tmp/rgss-evidence/inject.log'
TEXT = "\\C[2]赤い\\C[0]"

def mochi_evidence_log(message)
  File.open(LOG, 'a:UTF-8') { |file| file.puts("[#{Time.now.strftime('%H:%M:%S.%L')}] #{message}") }
rescue Exception
end

mochi_evidence_log "injector loaded ruby=#{RUBY_VERSION}"

Thread.new do
  begin
    # 等进入地图（VX 的 Scene_Map），再给 hook 的 TracePoint 留 2s 装好。
    300.times do
      scene = if defined?(SceneManager) && SceneManager.respond_to?(:scene)
                SceneManager.scene
              elsif defined?($scene)
                $scene
              end
      break if scene && scene.class.name == 'Scene_Map'
      sleep 0.1
    end
    sleep 2.0

    if defined?($game_message) && $game_message
      $game_message.texts.clear
      $game_message.texts.push(TEXT)
      mochi_evidence_log "PUSH first #{TEXT.inspect}"
    else
      mochi_evidence_log 'NO $game_message'
    end

    # 首遍：120ms PENDING → 显示原文；mock 800ms 后 fresh 写缓存。
    # 留足时间让第一屏被截图，再清掉窗口。
    sleep 4.0
    # 模拟玩家按确认键：terminate_message 会清 texts + 关掉 pause；
    # 只调 $game_message.clear 不够（Window_Message#update 先看 self.pause，永远走不到 close）。
    window = $scene.instance_variable_get(:@message_window) if defined?($scene) && $scene
    if window && window.respond_to?(:terminate_message)
      window.terminate_message
      mochi_evidence_log 'TERMINATE first message'
    else
      $game_message.clear
      mochi_evidence_log 'CLEAR first message (no window handle)'
    end

    sleep 1.5
    $game_message.texts.push(TEXT)
    mochi_evidence_log "PUSH second #{TEXT.inspect}"
  rescue Exception => error
    mochi_evidence_log "ERR #{error.class}: #{error.message}"
  end
end
