// Copyright 2026 Solara. Apache-2.0.

#ifndef CHROME_BROWSER_SOLARA_PIP_AC_PIP_CONTROLS_H_
#define CHROME_BROWSER_SOLARA_PIP_AC_PIP_CONTROLS_H_

#include <optional>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/timer/timer.h"
#include "chrome/browser/ui/views/overlay/back_to_tab_button.h"
#include "chrome/browser/ui/views/overlay/close_image_button.h"
#include "chrome/browser/ui/views/overlay/overlay_controls_fade_animation.h"
#include "chrome/browser/ui/views/overlay/playback_image_button.h"
#include "services/media_session/public/cpp/media_position.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/views/view.h"

namespace gfx {
class Canvas;
}

inline constexpr int kSolaraPipButtonMargin = 12;
inline constexpr int kSolaraPipButtonSize = 28;

class SolaraBackToTabButton : public OverlayWindowBackToTabButton {
  METADATA_HEADER(SolaraBackToTabButton, OverlayWindowBackToTabButton)

 public:
  explicit SolaraBackToTabButton(PressedCallback callback);
  SolaraBackToTabButton(const SolaraBackToTabButton&) = delete;
  SolaraBackToTabButton& operator=(const SolaraBackToTabButton&) = delete;
  ~SolaraBackToTabButton() override;

  void Place(const gfx::Size& window_size);

 protected:
  void OnPaintBackground(gfx::Canvas* canvas) override;
  void PaintButtonContents(gfx::Canvas* canvas) override;
};

class SolaraCloseButton : public CloseImageButton {
  METADATA_HEADER(SolaraCloseButton, CloseImageButton)

 public:
  static constexpr int kWidth = 29;

  explicit SolaraCloseButton(PressedCallback callback);
  SolaraCloseButton(const SolaraCloseButton&) = delete;
  SolaraCloseButton& operator=(const SolaraCloseButton&) = delete;
  ~SolaraCloseButton() override;

  void Place(const gfx::Size& window_size);

 protected:
  void OnPaintBackground(gfx::Canvas* canvas) override;
  void PaintButtonContents(gfx::Canvas* canvas) override;
};

class SolaraPlaybackButton : public PlaybackImageButton {
  METADATA_HEADER(SolaraPlaybackButton, PlaybackImageButton)

 public:
  explicit SolaraPlaybackButton(PressedCallback callback);
  SolaraPlaybackButton(const SolaraPlaybackButton&) = delete;
  SolaraPlaybackButton& operator=(const SolaraPlaybackButton&) = delete;
  ~SolaraPlaybackButton() override;

 protected:
  void OnPaintBackground(gfx::Canvas* canvas) override;
  void PaintButtonContents(gfx::Canvas* canvas) override;
};

class SolaraProgressBar : public views::View {
  METADATA_HEADER(SolaraProgressBar, views::View)

 public:
  static constexpr int kSlopX = 4;
  static constexpr int kSlopY = 6;
  static constexpr float kBarHeight = 5;

  explicit SolaraProgressBar(base::RepeatingCallback<void(double)> seek);
  SolaraProgressBar(const SolaraProgressBar&) = delete;
  SolaraProgressBar& operator=(const SolaraProgressBar&) = delete;
  ~SolaraProgressBar() override;

  void SetMediaPosition(const media_session::MediaPosition& position);

  void Place(const gfx::Size& window_size);

  void OnPaint(gfx::Canvas* canvas) override;
  bool OnMousePressed(const ui::MouseEvent& event) override;
  bool OnMouseDragged(const ui::MouseEvent& event) override;
  void OnMouseReleased(const ui::MouseEvent& event) override;
  void OnMouseCaptureLost() override;
  ui::Cursor GetCursor(const ui::MouseEvent& event) override;

 private:
  double FractionAt(int x) const;
  void RepaintIfDrawn();

  base::RepeatingCallback<void(double)> seek_;
  media_session::MediaPosition position_;
  std::optional<double> drag_fraction_;
  bool dragging_ = false;
  base::RepeatingTimer timer_;
};

class SolaraControlsFadeAnimation : public OverlayControlsFadeAnimation {
 public:
  SolaraControlsFadeAnimation(
      const std::vector<raw_ptr<views::View>>& controls,
      Type type);
  SolaraControlsFadeAnimation(const SolaraControlsFadeAnimation&) =
      delete;
  SolaraControlsFadeAnimation& operator=(
      const SolaraControlsFadeAnimation&) = delete;
  ~SolaraControlsFadeAnimation() override;

  void AnimateToState(double state) override;
};

#endif
