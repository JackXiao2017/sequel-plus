//
//  PGConstants.m
//  PostgresKit
//
//  Copyright (c) 2008-2009 David Thorpe, djt@mutablelogic.com
//
//  Forked by the Sequel Pro Team on July 22, 2012.
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

// Connection defaults
const NSUInteger PGPostgresConnectionDefaultTimeout    = 30;
const NSUInteger PGPostgresConnectionDefaultServerPort = 5432;
const NSUInteger PGPostgresConnectionDefaultKeepAlive  = 60;

NSString *PGPostgresConnectionDefaultEncoding              = @"UNICODE";
NSString *PGPostgresConnectionErrorDomain                  = @"PGPostgresConnectionError";
NSStringEncoding PGPostgresConnectionDefaultStringEncoding = NSUTF8StringEncoding;

// Server parameters
NSString *PGPostgresParameterServerEncoding   = @"server_encoding";
NSString *PGPostgresParameterClientEncoding   = @"client_encoding";
NSString *PGPostgresParameterSuperUser        = @"is_superuser";
NSString *PGPostgresParameterTimeZone         = @"TimeZone";
NSString *PGPostgresParameterIntegerDateTimes = @"integer_datetimes";

// Connection parameters
const char *PGPostgresKitApplicationName     = "PostgresKit";
const char *PGPostgresApplicationParam       = "application_name";
const char *PGPostgresUserParam              = "user";
const char *PGPostgresHostParam              = "host";
const char *PGPostgresPasswordParam          = "password";
const char *PGPostgresPortParam              = "port";
const char *PGPostgresDatabaseParam          = "dbname";
const char *PGPostgresClientEncodingParam    = "client_encoding";
const char *PGPostgresKeepAliveParam         = "keepalives";
const char *PGPostgresKeepAliveIntervalParam = "keepalives_interval";
const char *PGPostgresSSLModeParam           = "sslmode";
const char *PGPostgresSSLRootCertParam       = "sslrootcert";
const char *PGPostgresSSLCertParam           = "sslcert";
const char *PGPostgresSSLKeyParam            = "sslkey";
const char *PGPostgresOptionsParam           = "options";
const char *PGPostgresOptionsValue           = "-c datestyle=ISO -c intervalstyle=postgres -c extra_float_digits=1";
