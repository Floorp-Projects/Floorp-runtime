#include "FloorpLinuxTaskbar.h"

#include "nsCOMPtr.h"
#include "nsError.h"
#include "nsGlobalWindowOuter.h"
#include "nsIWidget.h"
#include "nsISupportsImpl.h"
#include "nsPIDOMWindow.h"
#include "nsReadableUtils.h"
#include "nsString.h"

#include "mozilla/Assertions.h"

#if defined(MOZ_WIDGET_GTK)

#  include <gtk/gtk.h>
#  include <gdk-pixbuf/gdk-pixbuf.h>
#  ifdef MOZ_WAYLAND
#    include <gdk/gdkwayland.h>
#    include <dlfcn.h>
#  endif
#endif

namespace mozilla {

FloorpLinuxTaskbar::FloorpLinuxTaskbar() = default;

FloorpLinuxTaskbar::~FloorpLinuxTaskbar() = default;

NS_IMPL_ISUPPORTS(FloorpLinuxTaskbar, nsIFloorpLinuxTaskbar)

#if defined(MOZ_WIDGET_GTK)
static already_AddRefed<nsIWidget> GetWidgetForWindow(
    mozIDOMWindowProxy* aWindow) {
  if (NS_WARN_IF(!aWindow)) {
    return nullptr;
  }

  nsGlobalWindowOuter* globalWindow = nsGlobalWindowOuter::Cast(aWindow);
  if (NS_WARN_IF(!globalWindow)) {
    return nullptr;
  }

  nsCOMPtr<nsIWidget> widget = globalWindow->GetMainWidget();
  if (widget) {
    return widget.forget();
  }

  if (nsIWidget* nearestWidget = globalWindow->GetNearestWidget()) {
    return do_AddRef(nearestWidget);
  }

  return nullptr;
}

static GtkWidget* GetGtkWidgetForWindow(mozIDOMWindowProxy* aWindow) {
  nsCOMPtr<nsIWidget> widget = GetWidgetForWindow(aWindow);
  if (!widget) {
    return nullptr;
  }

  if (nsIWidget* topLevel = widget->GetTopLevelWidget()) {
    widget = topLevel;
  }

  if (GtkWidget* gtkWidget = static_cast<GtkWidget*>(
          widget->GetNativeData(NS_NATIVE_SHELLWIDGET))) {
    return gtkWidget;
  }

  GdkWindow* gdkWindow =
      static_cast<GdkWindow*>(widget->GetNativeData(NS_NATIVE_WINDOW));
  if (!gdkWindow) {
    return nullptr;
  }

  GdkWindow* toplevelWindow = gdk_window_get_toplevel(gdkWindow);
  if (!toplevelWindow) {
    return nullptr;
  }

  gpointer userData = nullptr;
  gdk_window_get_user_data(toplevelWindow, &userData);
  return GTK_WIDGET(userData);
}
#endif

NS_IMETHODIMP
FloorpLinuxTaskbar::SetWindowClass(mozIDOMWindowProxy* aWindow,
                                   const nsAString& aWindowClass,
                                   const nsAString& aWindowTitle) {
#if !defined(MOZ_WIDGET_GTK)
  return NS_ERROR_NOT_IMPLEMENTED;
#else
  if (aWindowClass.IsEmpty()) {
    return NS_OK;
  }

  nsAutoString className(aWindowClass);

  GtkWidget* gtkWidget = GetGtkWidgetForWindow(aWindow);
  if (!gtkWidget) {
    return NS_ERROR_FAILURE;
  }

  NS_ConvertUTF16toUTF8 asciiClass(className);
  gtk_window_set_wmclass(GTK_WINDOW(gtkWidget), asciiClass.get(),
                         asciiClass.get());
  gtk_window_set_role(GTK_WINDOW(gtkWidget), asciiClass.get());

#ifdef MOZ_WAYLAND
  GdkDisplay* display = gtk_widget_get_display(gtkWidget);
  if (GDK_IS_WAYLAND_DISPLAY(display)) {
    GdkWindow* window = gtk_widget_get_window(gtkWidget);
    if (!window) {
      gtk_widget_realize(gtkWidget);
      window = gtk_widget_get_window(gtkWidget);
    }

    if (window) {
      static auto sGdkWaylandWindowSetApplicationId =
          (void (*)(GdkWindow*, const char*))dlsym(
              RTLD_DEFAULT, "gdk_wayland_window_set_application_id");

      if (sGdkWaylandWindowSetApplicationId) {
        sGdkWaylandWindowSetApplicationId(window, asciiClass.get());
      }
    }
  }
#endif
  return NS_OK;
#endif
}

NS_IMETHODIMP
FloorpLinuxTaskbar::SetWindowIconFromPath(mozIDOMWindowProxy* aWindow,
                                          const nsAString& aIconPath) {
#if !defined(MOZ_WIDGET_GTK)
  return NS_ERROR_NOT_IMPLEMENTED;
#else
  if (aIconPath.IsEmpty()) {
    return NS_OK;
  }

  GtkWidget* gtkWidget = GetGtkWidgetForWindow(aWindow);
  if (NS_WARN_IF(!gtkWidget)) {
    return NS_ERROR_FAILURE;
  }

  NS_ConvertUTF16toUTF8 iconPath(aIconPath);

  GError* error = nullptr;
  GdkPixbuf* icon = gdk_pixbuf_new_from_file(iconPath.get(), &error);
  if (!icon) {
    if (error) {
      g_error_free(error);
    }
    return NS_ERROR_FILE_NOT_FOUND;
  }

  gtk_window_set_icon(GTK_WINDOW(gtkWidget), icon);
  g_object_unref(icon);
  return NS_OK;
#endif
}

}  // namespace mozilla

