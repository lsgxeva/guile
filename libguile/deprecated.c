/* This file contains definitions for deprecated features.  When you
   deprecate something, move it here when that is feasible.
*/

/* Copyright (C) 2003, 2004, 2006, 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015 Free Software Foundation, Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * as published by the Free Software Foundation; either version 3 of
 * the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
 * 02110-1301 USA
 */

#ifdef HAVE_CONFIG_H
# include <config.h>
#endif

#define SCM_BUILDING_DEPRECATED_CODE

#include "libguile/_scm.h"
#include "libguile/deprecation.h"

#if (SCM_ENABLE_DEPRECATED == 1)



SCM
scm_internal_dynamic_wind (scm_t_guard before,
			   scm_t_inner inner,
			   scm_t_guard after,
			   void *inner_data,
			   void *guard_data)
{
  SCM ans;

  scm_c_issue_deprecation_warning
    ("`scm_internal_dynamic_wind' is deprecated.  "
     "Use the `scm_dynwind_begin' / `scm_dynwind_end' API instead.");

  scm_dynwind_begin (SCM_F_DYNWIND_REWINDABLE);
  scm_dynwind_rewind_handler (before, guard_data, SCM_F_WIND_EXPLICITLY);
  scm_dynwind_unwind_handler (after, guard_data, SCM_F_WIND_EXPLICITLY);
  ans = inner (inner_data);
  scm_dynwind_end ();
  return ans;
}



SCM
scm_immutable_cell (scm_t_bits car, scm_t_bits cdr)
{
  scm_c_issue_deprecation_warning
    ("scm_immutable_cell is deprecated.  Use scm_cell instead.");

  return scm_cell (car, cdr);
}

SCM
scm_immutable_double_cell (scm_t_bits car, scm_t_bits cbr,
			   scm_t_bits ccr, scm_t_bits cdr)
{
  scm_c_issue_deprecation_warning
    ("scm_immutable_double_cell is deprecated.  Use scm_double_cell instead.");

  return scm_double_cell (car, cbr, ccr, cdr);
}




SCM_GLOBAL_SYMBOL (scm_memory_alloc_key, "memory-allocation-error");
void
scm_memory_error (const char *subr)
{
  scm_c_issue_deprecation_warning
    ("scm_memory_error is deprecated.  Use scm_report_out_of_memory to raise "
     "an exception, or abort() to cause the program to exit.");

  fprintf (stderr, "FATAL: memory error in %s\n", subr);
  abort ();
}




#define BUFFSIZE 32		/* big enough for most uses */
#define SPEC_OF(x)  SCM_SLOT (x, scm_si_specializers)

static SCM
scm_i_vector2list (SCM l, long len)
{
  long j;
  SCM z = scm_c_make_vector (len, SCM_UNDEFINED);

  for (j = 0; j < len; j++, l = SCM_CDR (l)) {
    SCM_SIMPLE_VECTOR_SET (z, j, SCM_CAR (l));
  }
  return z;
}

static int
applicablep (SCM actual, SCM formal)
{
  /* We already know that the cpl is well formed. */
  return scm_is_true (scm_c_memq (formal, SCM_SLOT (actual, scm_si_cpl)));
}

static int
more_specificp (SCM m1, SCM m2, SCM const *targs)
{
  register SCM s1, s2;
  register long i;
  /*
   * Note:
   *   m1 and m2 can have != length (i.e. one can be one element longer than the
   * other when we have a dotted parameter list). For instance, with the call
   *   (M 1)
   * with
   *   (define-method M (a . l) ....)
   *   (define-method M (a) ....)
   *
   * we consider that the second method is more specific.
   *
   * BTW, targs is an array of types. We don't need it's size since
   * we already know that m1 and m2 are applicable (no risk to go past
   * the end of this array).
   *
   */
  for (i=0, s1=SPEC_OF(m1), s2=SPEC_OF(m2); ; i++, s1=SCM_CDR(s1), s2=SCM_CDR(s2)) {
    if (scm_is_null(s1)) return 1;
    if (scm_is_null(s2)) return 0;
    if (!scm_is_eq (SCM_CAR(s1), SCM_CAR(s2))) {
      register SCM l, cs1 = SCM_CAR(s1), cs2 = SCM_CAR(s2);

      for (l = SCM_SLOT (targs[i], scm_si_cpl);   ; l = SCM_CDR(l)) {
	if (scm_is_eq (cs1, SCM_CAR (l)))
	  return 1;
	if (scm_is_eq (cs2, SCM_CAR (l)))
	  return 0;
      }
      return 0;/* should not occur! */
    }
  }
  return 0; /* should not occur! */
}

static SCM
sort_applicable_methods (SCM method_list, long size, SCM const *targs)
{
  long i, j, incr;
  SCM *v, vector = SCM_EOL;
  SCM buffer[BUFFSIZE];
  SCM save = method_list;
  scm_t_array_handle handle;

  /* For reasonably sized method_lists we can try to avoid all the
   * consing and reorder the list in place...
   * This idea is due to David McClain <Dave_McClain@msn.com>
   */
  if (size <= BUFFSIZE)
    {
      for (i = 0;  i < size; i++)
	{
	  buffer[i]   = SCM_CAR (method_list);
	  method_list = SCM_CDR (method_list);
	}
      v = buffer;
    }
  else
    {
      /* Too many elements in method_list to keep everything locally */
      vector = scm_i_vector2list (save, size);
      v = scm_vector_writable_elements (vector, &handle, NULL, NULL);
    }

  /* Use a simple shell sort since it is generally faster than qsort on
   * small vectors (which is probably mostly the case when we have to
   * sort a list of applicable methods).
   */
  for (incr = size / 2; incr; incr /= 2)
    {
      for (i = incr; i < size; i++)
	{
	  for (j = i - incr; j >= 0; j -= incr)
	    {
	      if (more_specificp (v[j], v[j+incr], targs))
		break;
	      else
		{
		  SCM tmp = v[j + incr];
		  v[j + incr] = v[j];
		  v[j] = tmp;
		}
	    }
	}
    }

  if (size <= BUFFSIZE)
    {
      /* We did it in locally, so restore the original list (reordered) in-place */
      for (i = 0, method_list = save; i < size; i++, v++)
	{
	  SCM_SETCAR (method_list, *v);
	  method_list = SCM_CDR (method_list);
	}
      return save;
    }

  /* If we are here, that's that we did it the hard way... */
  scm_array_handle_release (&handle);
  return scm_vector_to_list (vector);
}

SCM
scm_compute_applicable_methods (SCM gf, SCM args, long len, int find_method_p)
{
  register long i;
  long count = 0;
  SCM l, fl, applicable = SCM_EOL;
  SCM save = args;
  SCM buffer[BUFFSIZE];
  SCM const *types;
  SCM *p;
  SCM tmp = SCM_EOL;
  scm_t_array_handle handle;

  scm_c_issue_deprecation_warning
    ("scm_compute_applicable_methods is deprecated.  Use "
     "`compute-applicable-methods' from Scheme instead.");

  /* Build the list of arguments types */
  if (len >= BUFFSIZE) 
    {
      tmp = scm_c_make_vector (len, SCM_UNDEFINED);
      types = p = scm_vector_writable_elements (tmp, &handle, NULL, NULL);

    /*
      note that we don't have to work to reset the generation
      count. TMP is a new vector anyway, and it is found
      conservatively.
    */
    }
  else
    types = p = buffer;

  for (  ; !scm_is_null (args); args = SCM_CDR (args))
    *p++ = scm_class_of (SCM_CAR (args));
  
  /* Build a list of all applicable methods */
  for (l = scm_generic_function_methods (gf); !scm_is_null (l); l = SCM_CDR (l))
    {
      fl = SPEC_OF (SCM_CAR (l));
      for (i = 0; ; i++, fl = SCM_CDR (fl))
	{
	  if (SCM_INSTANCEP (fl)
	      /* We have a dotted argument list */
	      || (i >= len && scm_is_null (fl)))
	    {	/* both list exhausted */
	      applicable = scm_cons (SCM_CAR (l), applicable);
	      count     += 1;
	      break;
	    }
	  if (i >= len
	      || scm_is_null (fl)
	      || !applicablep (types[i], SCM_CAR (fl)))
	    break;
	}
    }

  if (len >= BUFFSIZE)
      scm_array_handle_release (&handle);

  if (count == 0)
    {
      if (find_method_p)
	return SCM_BOOL_F;
      scm_call_2 (scm_no_applicable_method, gf, save);
      /* if we are here, it's because no-applicable-method hasn't signaled an error */
      return SCM_BOOL_F;
    }

  return (count == 1
	  ? applicable
	  : sort_applicable_methods (applicable, count, types));
}

SCM_SYMBOL (sym_compute_applicable_methods, "compute-applicable-methods");

SCM
scm_find_method (SCM l)
#define FUNC_NAME "find-method"
{
  SCM gf;
  long len = scm_ilength (l);

  if (len == 0)
    SCM_WRONG_NUM_ARGS ();

  scm_c_issue_deprecation_warning
    ("scm_find_method is deprecated.  Use `compute-applicable-methods' "
     "from Scheme instead.");

  gf = SCM_CAR(l); l = SCM_CDR(l);
  SCM_VALIDATE_GENERIC (1, gf);
  if (scm_is_null (SCM_SLOT (gf, scm_si_methods)))
    SCM_MISC_ERROR ("no methods for generic ~S", scm_list_1 (gf));

  return scm_compute_applicable_methods (gf, l, len - 1, 1);
}
#undef FUNC_NAME

SCM
scm_basic_make_class (SCM meta, SCM name, SCM dsupers, SCM dslots)
{
  scm_c_issue_deprecation_warning
    ("scm_basic_make_class is deprecated.  Use `define-class' in Scheme,"
     "or use `(make META #:name NAME #:dsupers DSUPERS #:slots DSLOTS)' "
     "in Scheme.");

  return scm_make_standard_class (meta, name, dsupers, dslots);
}




void
scm_i_init_deprecated ()
{
#include "libguile/deprecated.x"
}

#endif
