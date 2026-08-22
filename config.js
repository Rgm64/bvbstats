/* Supabase connection details.
 *
 * Fill these in from your project's Settings -> API page. Both are safe to
 * commit: the anon key is designed to sit in browser code, and the row-level
 * security policies in supabase/schema.sql are what actually protect the data.
 *
 * NEVER put the `service_role` key here. That one bypasses every policy.
 *
 * Left blank, the app runs exactly as it does today: fully functional, stored
 * on this device only, with no sign-in offered.
 */
window.BV_CONFIG = {
  url: '',      // e.g. 'https://abcdefghijklm.supabase.co'
  anonKey: '',  // the long "anon public" key
};
