//
//  PGPostgresLibpqShims.c
//  PostgresKit
//
//  The static libpq.a built from the PostgreSQL 18 sources calls the public encoding helpers
//  pg_char_to_encoding() and pg_encoding_to_char(), but the matching libpgcommon.a exports
//  them under their '_private' names (USE_PRIVATE_ENCODING_FUNCS, which exists so a shared libpq 
//  doesn't clash with the encoding functions of the application linking it). Bridge the two here.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not 
//  use this file except in compliance with the License. You may obtain a copy of 
//  the License at
// 
//  http://www.apache.org/licenses/LICENSE-2.0
// 
//  Unless required by applicable law or agreed to in writing, software 
//  distributed under the License is distributed on an "AS IS" BASIS, WITHOUT 
//  WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the 
//  License for the specific language governing permissions and limitations under
//  the License.

extern int pg_char_to_encoding_private(const char *name);
extern const char *pg_encoding_to_char_private(int encoding);

int pg_char_to_encoding(const char *name);
const char *pg_encoding_to_char(int encoding);

int pg_char_to_encoding(const char *name)
{
	return pg_char_to_encoding_private(name);
}

const char *pg_encoding_to_char(int encoding)
{
	return pg_encoding_to_char_private(encoding);
}
