/*	Copyright (C) 1995,1996,1997,1998 Free Software Foundation, Inc.
 * 
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2, or (at your option)
 * any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this software; see the file COPYING.  If not, write to
 * the Free Software Foundation, Inc., 59 Temple Place, Suite 330,
 * Boston, MA 02111-1307 USA
 *
 * As a special exception, the Free Software Foundation gives permission
 * for additional uses of the text contained in its release of GUILE.
 *
 * The exception is that, if you link the GUILE library with other files
 * to produce an executable, this does not by itself cause the
 * resulting executable to be covered by the GNU General Public License.
 * Your use of that executable is in no way restricted on account of
 * linking the GUILE library code into it.
 *
 * This exception does not however invalidate any other reasons why
 * the executable file might be covered by the GNU General Public License.
 *
 * This exception applies only to the code released by the
 * Free Software Foundation under the name GUILE.  If you copy
 * code from other Free Software Foundation releases into a copy of
 * GUILE, as the General Public License permits, the exception does
 * not apply to the code that you add in this way.  To avoid misleading
 * anyone as to the status of such modified files, you must delete
 * this exception notice from them.
 *
 * If you write modifications of your own for GUILE, it is your choice
 * whether to permit this exception to apply to your modifications.
 * If you do not wish that, delete this exception notice.  */


#include <stdio.h>
#include "_scm.h"

#include "scmsigs.h"
#include "simpos.h"

#ifdef HAVE_STRING_H
#include <string.h>
#endif
#ifdef HAVE_UNISTD_H
#include <unistd.h>
#endif


extern int system();


SCM_PROC(s_system, "system", 0, 1, 0, scm_system);

SCM
scm_system(cmd)
     SCM cmd;
{
  int rv;

  if (SCM_UNBNDP (cmd))
    {
#ifdef HAVE_SYSTEM
      rv = system (NULL);
#else
      rv = 0;
#endif
      return rv ? SCM_BOOL_T : SCM_BOOL_F;
    }
  SCM_ASSERT(SCM_NIMP(cmd) && SCM_ROSTRINGP(cmd), cmd, SCM_ARG1, s_system);
#ifdef HAVE_SYSTEM
  SCM_DEFER_INTS;
  errno = 0;
  if (SCM_ROSTRINGP (cmd))
    cmd = scm_makfromstr (SCM_ROCHARS (cmd), SCM_ROLENGTH (cmd), 0);
  rv = system(SCM_ROCHARS(cmd));
  if (rv == -1 || (rv == 127 && errno != 0))
    scm_syserror (s_system);
  SCM_ALLOW_INTS;
  return SCM_MAKINUM (rv);
#else
  scm_sysmissing (s_system);
#endif
}

extern char *getenv();
SCM_PROC (s_getenv, "getenv", 1, 0, 0, scm_getenv);

SCM
scm_getenv(nam)
     SCM nam;
{
  char *val;
  SCM_ASSERT(SCM_NIMP(nam) && SCM_ROSTRINGP(nam), nam, SCM_ARG1, s_getenv);
  if (SCM_ROSTRINGP (nam))
    nam = scm_makfromstr (SCM_ROCHARS (nam), SCM_ROLENGTH (nam), 0);
  val = getenv(SCM_CHARS(nam));
  return (val) ? scm_makfromstr(val, (scm_sizet)strlen(val), 0) : SCM_BOOL_F;
}

SCM_PROC (s_primitive_exit, "primitive-exit", 0, 1, 0, scm_primitive_exit);
SCM
scm_primitive_exit (SCM status)
{
  int cstatus = 0;
  if (!SCM_UNBNDP (status))
    {
      SCM_ASSERT (SCM_INUMP (status), status, SCM_ARG1, s_primitive_exit);
      cstatus = SCM_INUM (status);
    }
  exit (cstatus);
}


void
scm_init_simpos ()
{
#include "simpos.x"
}

