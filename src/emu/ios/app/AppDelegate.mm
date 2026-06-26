/*
 * Copyright (c) 2024 EKA2L1 Team.
 *
 * This file is part of EKA2L1 project.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */
#import "AppDelegate.h"
#import "RootViewController.h"

#include <ios/emu_bridge.h>

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    RootViewController *root = [[RootViewController alloc] init];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];

    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    if (launchURL) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [root handleIncomingFileURL:launchURL];
        });
    }
    return YES;
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    UIViewController *root = self.window.rootViewController;
    if ([root isKindOfClass:[RootViewController class]]) {
        [(RootViewController *)root handleIncomingFileURL:url];
        return YES;
    }
    return NO;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    eka2l1::ios::bridge::pause();
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    eka2l1::ios::bridge::resume();
}

- (void)applicationWillTerminate:(UIApplication *)application {
    eka2l1::ios::bridge::shutdown();
}

@end
