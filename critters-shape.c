/* critters-shape.c --- Clip X windows to a set of rectangles  */

/* Dynamic module for critters.el.  It uses the X Shape extension to
   cut the critter's child frame down to the opaque pixels of the
   sprite, so no rectangular background is drawn around it.

   XCB is used instead of Xlib because Xlib's default error handler
   exits the process, and replacing it would also replace Emacs's.  */

#include <emacs-module.h>
#include <stdlib.h>
#include <string.h>
#include <xcb/xcb.h>
#include <xcb/shape.h>

int plugin_is_GPL_compatible;

static xcb_connection_t *conn;

static emacs_value
signal_error (emacs_env *env, const char *msg)
{
  emacs_value str = env->make_string (env, msg, strlen (msg));
  env->non_local_exit_signal (env, env->intern (env, "error"),
                              env->funcall (env, env->intern (env, "list"),
                                            1, &str));
  return env->intern (env, "nil");
}

static int
ensure_connection (emacs_env *env, emacs_value display)
{
  ptrdiff_t len = 0;
  char *name;

  if (conn && !xcb_connection_has_error (conn))
    return 1;
  if (conn)
    xcb_disconnect (conn);

  env->copy_string_contents (env, display, NULL, &len);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return 0;
  name = malloc (len);
  if (!name)
    return 0;
  env->copy_string_contents (env, display, name, &len);
  conn = xcb_connect (name, NULL);
  free (name);

  if (xcb_connection_has_error (conn))
    {
      xcb_disconnect (conn);
      conn = NULL;
      return 0;
    }
  return 1;
}

/* (critters-shape-set DISPLAY WINDOW RECTS) */
static emacs_value
shape_set (emacs_env *env, ptrdiff_t nargs, emacs_value *args, void *data)
{
  xcb_window_t window;
  ptrdiff_t n;
  xcb_rectangle_t *rects;
  xcb_generic_event_t *event;

  if (!ensure_connection (env, args[0]))
    return signal_error (env, "critters-shape: cannot connect to X display");

  window = env->extract_integer (env, args[1]);
  n = env->vec_size (env, args[2]) / 4;
  rects = malloc ((n ? n : 1) * sizeof *rects);
  if (!rects)
    return signal_error (env, "critters-shape: out of memory");
  for (ptrdiff_t i = 0; i < n; i++)
    {
      rects[i].x = env->extract_integer (env, env->vec_get (env, args[2], 4 * i));
      rects[i].y = env->extract_integer (env, env->vec_get (env, args[2], 4 * i + 1));
      rects[i].width = env->extract_integer (env, env->vec_get (env, args[2], 4 * i + 2));
      rects[i].height = env->extract_integer (env, env->vec_get (env, args[2], 4 * i + 3));
    }
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    {
      free (rects);
      return env->intern (env, "nil");
    }

  /* Don't wait for a reply, that would be a round trip to the X
     server on every sprite change.  Errors come back as events on our
     own connection instead, which are discarded.  */
  xcb_shape_rectangles (conn, XCB_SHAPE_SO_SET, XCB_SHAPE_SK_BOUNDING,
                        XCB_CLIP_ORDERING_UNSORTED, window, 0, 0, n, rects);
  free (rects);
  xcb_flush (conn);
  while ((event = xcb_poll_for_event (conn)))
    free (event);
  return env->intern (env, "t");
}

int
emacs_module_init (struct emacs_runtime *runtime)
{
  emacs_env *env;
  emacs_value fn, feature, args[2];

  if ((size_t) runtime->size < sizeof *runtime)
    return 1;
  env = runtime->get_environment (runtime);
  if ((size_t) env->size < sizeof (struct emacs_env_25))
    return 2;

  fn = env->make_function (env, 3, 3, shape_set,
                           "Clip X WINDOW on DISPLAY to RECTS.\n\n"
                           "WINDOW is an X window id.  RECTS is a flat vector\n"
                           "[X Y WIDTH HEIGHT ...] of rectangles in window pixels.\n\n"
                           "(fn DISPLAY WINDOW RECTS)",
                           NULL);
  args[0] = env->intern (env, "critters-shape-set");
  args[1] = fn;
  env->funcall (env, env->intern (env, "defalias"), 2, args);

  feature = env->intern (env, "critters-shape");
  env->funcall (env, env->intern (env, "provide"), 1, &feature);
  return 0;
}
