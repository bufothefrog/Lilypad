//
//  WindowAction.swift
//  Rectangle
//
//  Created by Ryan Hanson on 6/12/19.
//  Copyright © 2019 Ryan Hanson. All rights reserved.
//

import Foundation
import Carbon
import Cocoa
import MASShortcut

fileprivate let alt = NSEvent.ModifierFlags.option.rawValue
fileprivate let ctrl = NSEvent.ModifierFlags.control.rawValue
fileprivate let shift = NSEvent.ModifierFlags.shift.rawValue
fileprivate let cmd = NSEvent.ModifierFlags.command.rawValue

enum WindowAction: Int, Codable {
    case leftHalf = 0,
         rightHalf = 1,
         maximize = 2,
         maximizeHeight = 3,
         previousDisplay = 4,
         nextDisplay = 5,
         larger = 8,
         smaller = 9,
         bottomHalf = 10,
         topHalf = 11,
         center = 12,
         bottomLeft = 13,
         bottomRight = 14,
         topLeft = 15,
         topRight = 16,
         restore = 19,
         firstThird = 20,
         firstTwoThirds = 21,
         centerThird = 22,
         lastTwoThirds = 23,
         lastThird = 24,
         moveLeft = 25,
         moveRight = 26,
         moveUp = 27,
         moveDown = 28,
         almostMaximize = 29,
         centerHalf = 30,
         firstFourth = 31,
         secondFourth = 32,
         thirdFourth = 33,
         lastFourth = 34,
         firstThreeFourths = 35,
         lastThreeFourths = 36,
         specified = 43,
         reverseAll = 44,
         tileAll = 66,
         cascadeAll = 67,
         leftTodo = 68,
         rightTodo = 69,
         cascadeActiveApp = 70,
         centerProminently = 71,
         doubleHeightUp = 72,
         doubleHeightDown = 73,
         doubleWidthLeft = 74,
         doubleWidthRight = 75,
         halveHeightUp = 76,
         halveHeightDown = 77,
         halveWidthLeft = 78,
         halveWidthRight = 79,
         largerWidth = 80,
         smallerWidth = 81,
         largerHeight = 82,
         smallerHeight = 83,
         centerTwoThirds = 84,
         centerThreeFourths = 85,
         tileActiveApp = 86,
         topVerticalThird = 87,
         middleVerticalThird = 88,
         bottomVerticalThird = 89,
         topVerticalTwoThirds = 90,
         bottomVerticalTwoThirds = 91,
         displayOne = 120,
         displayTwo = 121,
         displayThree = 122,
         displayFour = 123,
         displayFive = 124,
         displaySix = 125,
         displaySeven = 126,
         displayEight = 127,
         displayNine = 128,
         gridMoveLeft = 129,
         gridMoveRight = 130,
         gridMoveUp = 131,
         gridMoveDown = 132,
         gridSpanLeft = 133,
         gridSpanRight = 134,
         gridSpanUp = 135,
         gridSpanDown = 136,
         activateLayoutSlot1 = 137,
         activateLayoutSlot2 = 138,
         activateLayoutSlot3 = 139,
         activateLayoutSlot4 = 140,
         activateLayoutSlot5 = 141,
         activateLayoutSlot6 = 142,
         activateLayoutSlot7 = 143,
         activateLayoutSlot8 = 144,
         activateLayoutSlot9 = 145

    // Order matters here - it's used in the menu
    static let active = [leftHalf, rightHalf, centerHalf, topHalf, bottomHalf,
                         topLeft, topRight, bottomLeft, bottomRight,
                         firstThird, centerThird, lastThird, firstTwoThirds, centerTwoThirds, lastTwoThirds,
                         topVerticalThird, middleVerticalThird, bottomVerticalThird, topVerticalTwoThirds, bottomVerticalTwoThirds,
                         maximize, almostMaximize, maximizeHeight, larger, smaller, largerWidth, smallerWidth, largerHeight, smallerHeight,
                         center, centerProminently, restore,
                         nextDisplay, previousDisplay,
                         moveLeft, moveRight, moveUp, moveDown,
                         gridMoveLeft, gridMoveRight, gridMoveUp, gridMoveDown,
                         gridSpanLeft, gridSpanRight, gridSpanUp, gridSpanDown,
                         activateLayoutSlot1, activateLayoutSlot2, activateLayoutSlot3, activateLayoutSlot4, activateLayoutSlot5,
                         activateLayoutSlot6, activateLayoutSlot7, activateLayoutSlot8, activateLayoutSlot9,
                         firstFourth, secondFourth, thirdFourth, lastFourth, firstThreeFourths, centerThreeFourths, lastThreeFourths,
                         specified, reverseAll,
                         doubleHeightUp, doubleHeightDown, doubleWidthLeft, doubleWidthRight,
                         halveHeightUp, halveHeightDown, halveWidthLeft, halveWidthRight,
                         tileAll, cascadeAll,
                         leftTodo, rightTodo,
                         cascadeActiveApp, tileActiveApp,
                         displayOne, displayTwo, displayThree, displayFour, displayFive,
                         displaySix, displaySeven, displayEight, displayNine
    ]

    func post() {
        NotificationCenter.default.post(name: notificationName, object: ExecutionParameters(self))
    }
    
    func postMenu() {
        NotificationCenter.default.post(name: notificationName, object: ExecutionParameters(self, source: .menuItem))
    }

    func postSnap(windowElement: AccessibilityElement?, windowId: CGWindowID?, screen: NSScreen) {
        NotificationCenter.default.post(name: notificationName, object: ExecutionParameters(self, updateRestoreRect: false, screen: screen, windowElement: windowElement, windowId: windowId, source: .dragToSnap))
    }
    
    func postUrl() {
        NotificationCenter.default.post(name: notificationName, object: ExecutionParameters(self, source: .url))
    }
    
    func postTitleBar(windowElement: AccessibilityElement?) {
        NotificationCenter.default.post(name: notificationName, object: ExecutionParameters(self, windowElement: windowElement, source: .titleBar))
    }

    // Determines where separators should be used in the menu
    var firstInGroup: Bool {
        switch self {
        case .leftHalf, .topLeft, .firstThird, .maximize, .almostMaximize, .nextDisplay, .moveLeft, .firstFourth:
            return true
        default:
            return false
        }
    }

    var name: String {
        switch self {
        case .leftHalf: return "leftHalf"
        case .rightHalf: return "rightHalf"
        case .maximize: return "maximize"
        case .maximizeHeight: return "maximizeHeight"
        case .previousDisplay: return "previousDisplay"
        case .nextDisplay: return "nextDisplay"
        case .larger: return "larger"
        case .smaller: return "smaller"
        case .bottomHalf: return "bottomHalf"
        case .topHalf: return "topHalf"
        case .center: return "center"
        case .bottomLeft: return "bottomLeft"
        case .bottomRight: return "bottomRight"
        case .topLeft: return "topLeft"
        case .topRight: return "topRight"
        case .restore: return "restore"
        case .firstThird: return "firstThird"
        case .firstTwoThirds: return "firstTwoThirds"
        case .centerThird: return "centerThird"
        case .centerTwoThirds: return "centerTwoThirds"
        case .lastTwoThirds: return "lastTwoThirds"
        case .lastThird: return "lastThird"
        case .moveLeft: return "moveLeft"
        case .moveRight: return "moveRight"
        case .moveUp: return "moveUp"
        case .moveDown: return "moveDown"
        case .almostMaximize: return "almostMaximize"
        case .centerHalf: return "centerHalf"
        case .firstFourth: return "firstFourth"
        case .secondFourth: return "secondFourth"
        case .thirdFourth: return "thirdFourth"
        case .lastFourth: return "lastFourth"
        case .firstThreeFourths: return "firstThreeFourths"
        case .centerThreeFourths: return "centerThreeFourths"
        case .lastThreeFourths: return "lastThreeFourths"
        case .specified: return "specified"
        case .reverseAll: return "reverseAll"
        case .doubleHeightUp: return "doubleHeightUp"
        case .doubleHeightDown: return "doubleHeightDown"
        case .doubleWidthLeft: return "doubleWidthLeft"
        case .doubleWidthRight: return "doubleWidthRight"
        case .halveHeightUp: return "halveHeightUp"
        case .halveHeightDown: return "halveHeightDown"
        case .halveWidthLeft: return "halveWidthLeft"
        case .halveWidthRight: return "halveWidthRight"
        case .tileAll: return "tileAll"
        case .cascadeAll: return "cascadeAll"
        case .leftTodo: return "leftTodo"
        case .rightTodo: return "rightTodo"
        case .cascadeActiveApp: return "cascadeActiveApp"
        case .tileActiveApp: return "tileActiveApp"
        case .centerProminently: return "centerProminently"
        case .largerWidth: return "largerWidth"
        case .smallerWidth: return "smallerWidth"
        case .largerHeight: return "largerHeight"
        case .smallerHeight: return "smallerHeight"
        case .topVerticalThird: return "topVerticalThird"
        case .middleVerticalThird: return "middleVerticalThird"
        case .bottomVerticalThird: return "bottomVerticalThird"
        case .topVerticalTwoThirds: return "topVerticalTwoThirds"
        case .bottomVerticalTwoThirds: return "bottomVerticalTwoThirds"
        case .displayOne: return "displayOne"
        case .displayTwo: return "displayTwo"
        case .displayThree: return "displayThree"
        case .displayFour: return "displayFour"
        case .displayFive: return "displayFive"
        case .displaySix: return "displaySix"
        case .displaySeven: return "displaySeven"
        case .displayEight: return "displayEight"
        case .displayNine: return "displayNine"
        case .gridMoveLeft: return "gridMoveLeft"
        case .gridMoveRight: return "gridMoveRight"
        case .gridMoveUp: return "gridMoveUp"
        case .gridMoveDown: return "gridMoveDown"
        case .gridSpanLeft: return "gridSpanLeft"
        case .gridSpanRight: return "gridSpanRight"
        case .gridSpanUp: return "gridSpanUp"
        case .gridSpanDown: return "gridSpanDown"
        case .activateLayoutSlot1: return "activateLayoutSlot1"
        case .activateLayoutSlot2: return "activateLayoutSlot2"
        case .activateLayoutSlot3: return "activateLayoutSlot3"
        case .activateLayoutSlot4: return "activateLayoutSlot4"
        case .activateLayoutSlot5: return "activateLayoutSlot5"
        case .activateLayoutSlot6: return "activateLayoutSlot6"
        case .activateLayoutSlot7: return "activateLayoutSlot7"
        case .activateLayoutSlot8: return "activateLayoutSlot8"
        case .activateLayoutSlot9: return "activateLayoutSlot9"
        }
    }

    /// The 1-based layout slot number for the `activateLayoutSlot*` actions (M9), or
    /// `nil` for any other action. The handler subtracts 1 for the array index.
    var layoutSlotNumber: Int? {
        switch self {
        case .activateLayoutSlot1: return 1
        case .activateLayoutSlot2: return 2
        case .activateLayoutSlot3: return 3
        case .activateLayoutSlot4: return 4
        case .activateLayoutSlot5: return 5
        case .activateLayoutSlot6: return 6
        case .activateLayoutSlot7: return 7
        case .activateLayoutSlot8: return 8
        case .activateLayoutSlot9: return 9
        default: return nil
        }
    }

    var displayIndex: Int? {
        switch self {
        case .displayOne: return 0
        case .displayTwo: return 1
        case .displayThree: return 2
        case .displayFour: return 3
        case .displayFive: return 4
        case .displaySix: return 5
        case .displaySeven: return 6
        case .displayEight: return 7
        case .displayNine: return 8
        default: return nil
        }
    }

    var displayName: String? {
        var key: String
        var value: String

        switch self {
        case .leftHalf:
            key = "Xc8-Sm-pig.title"
            value = "Left Half"
        case .rightHalf:
            key = "F8S-GI-LiB.title"
            value = "Right Half"
        case .maximize:
            key = "8oe-J2-oUU.title"
            value = "Maximize"
        case .maximizeHeight:
            key = "6DV-cd-fda.title"
            value = "Maximize Height"
        case .previousDisplay:
            key = "QwF-QN-YH7.title"
            value = "Previous Display"
        case .nextDisplay:
            key = "Jnd-Lc-nlh.title"
            value = "Next Display"
        case .larger:
            key = "Eah-KL-kbn.title"
            value = "Larger"
        case .smaller:
            key = "MzN-CJ-ASD.title"
            value = "Smaller"
        case .bottomHalf:
            key = "ec4-FB-fMa.title"
            value = "Bottom Half"
        case .topHalf:
            key = "d7y-s8-7GE.title"
            value = "Top Half"
        case .center:
            key = "8Bg-SZ-hDO.title"
            value = "Center"
        case .bottomLeft:
            key = "6ma-hP-5xX.title"
            value = "Bottom Left"
        case .bottomRight:
            key = "J6t-sg-Wwz.title"
            value = "Bottom Right"
        case .topLeft:
            key = "adp-cN-qkh.title"
            value = "Top Left"
        case .topRight:
            key = "0Ak-33-SM7.title"
            value = "Top Right"
        case .restore:
            key = "C9v-g0-DH8.title"
            value = "Restore"
        case .firstThird:
            key = "F12-EV-Lfz.title"
            value = "First Third"
        case .firstTwoThirds:
            key = "3zd-xE-oWl.title"
            value = "First Two Thirds"
        case .centerThird:
            key = "7YK-9Z-lzw.title"
            value = "Center Third"
        case .centerTwoThirds:
            key = "oSu-n4-8Yu.title"
            value = "Center Two Thirds"
        case .lastTwoThirds:
            key = "08q-Ce-1QL.title"
            value = "Last Two Thirds"
        case .lastThird:
            key = "cRm-wn-Yv6.title"
            value = "Last Third"
        case .moveLeft:
            key = "v2f-bX-xiM.title"
            value = "Move Left"
        case .moveRight:
            key = "rzr-Qq-702.title"
            value = "Move Right"
        case .moveUp:
            key = "HOm-BV-2jc.title"
            value = "Move Up"
        case .moveDown:
            key = "1Rc-Od-eP5.title"
            value = "Move Down"
        case .almostMaximize:
            key = "e57-QJ-6bL.title"
            value = "Almost Maximize"
        case .centerHalf:
            key = "bRX-dV-iAR.title"
            value = "Center Half"
        case .firstFourth:
            key = "Q6Q-6J-okH.title"
            value = "First Fourth"
        case .secondFourth:
            key = "Fko-xs-gN5.title"
            value = "Second Fourth"
        case .thirdFourth:
            key = "ZTK-rS-b17.title"
            value = "Third Fourth"
        case .lastFourth:
            key = "6HX-rn-VIp.title"
            value = "Last Fourth"
        case .firstThreeFourths:
            key = "T9Z-QF-gwc.title"
            value = "First Three Fourths"
        case .centerThreeFourths:
            key = "Vph-Z0-euH.title"
            value = "Center Three Fourths"
        case .lastThreeFourths:
            key = "nwX-h6-fwm.title"
            value = "Last Three Fourths"
        case .doubleHeightUp, .doubleHeightDown, .doubleWidthLeft, .doubleWidthRight, .halveHeightUp, .halveHeightDown, .halveWidthLeft, .halveWidthRight:
            return nil
        case .specified, .reverseAll, .tileAll, .cascadeAll, .leftTodo, .rightTodo, .cascadeActiveApp, .tileActiveApp:
            return nil
        case .centerProminently, .largerWidth, .smallerWidth, .largerHeight, .smallerHeight:
            return nil
        case .topVerticalThird, .middleVerticalThird, .bottomVerticalThird, .topVerticalTwoThirds, .bottomVerticalTwoThirds:
            return nil
        case .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive,
             .displaySix, .displaySeven, .displayEight, .displayNine:
            return nil
        case .gridMoveLeft:
            key = "gridMoveLeft.title"
            value = "Grid Move Left"
        case .gridMoveRight:
            key = "gridMoveRight.title"
            value = "Grid Move Right"
        case .gridMoveUp:
            key = "gridMoveUp.title"
            value = "Grid Move Up"
        case .gridMoveDown:
            key = "gridMoveDown.title"
            value = "Grid Move Down"
        case .gridSpanLeft:
            key = "gridSpanLeft.title"
            value = "Grid Span Left"
        case .gridSpanRight:
            key = "gridSpanRight.title"
            value = "Grid Span Right"
        case .gridSpanUp:
            key = "gridSpanUp.title"
            value = "Grid Span Up"
        case .gridSpanDown:
            key = "gridSpanDown.title"
            value = "Grid Span Down"
        case .activateLayoutSlot1:
            key = "activateLayoutSlot1.title"
            value = "Activate Layout Slot 1"
        case .activateLayoutSlot2:
            key = "activateLayoutSlot2.title"
            value = "Activate Layout Slot 2"
        case .activateLayoutSlot3:
            key = "activateLayoutSlot3.title"
            value = "Activate Layout Slot 3"
        case .activateLayoutSlot4:
            key = "activateLayoutSlot4.title"
            value = "Activate Layout Slot 4"
        case .activateLayoutSlot5:
            key = "activateLayoutSlot5.title"
            value = "Activate Layout Slot 5"
        case .activateLayoutSlot6:
            key = "activateLayoutSlot6.title"
            value = "Activate Layout Slot 6"
        case .activateLayoutSlot7:
            key = "activateLayoutSlot7.title"
            value = "Activate Layout Slot 7"
        case .activateLayoutSlot8:
            key = "activateLayoutSlot8.title"
            value = "Activate Layout Slot 8"
        case .activateLayoutSlot9:
            key = "activateLayoutSlot9.title"
            value = "Activate Layout Slot 9"
        }

        return NSLocalizedString(key, tableName: "Main", value: value, comment: "")
    }

    var notificationName: Notification.Name {
        return Notification.Name(name)
    }

    var resizes: Bool {
        switch self {
        case .center, .centerProminently, .nextDisplay, .previousDisplay,
             .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive,
             .displaySix, .displaySeven, .displayEight, .displayNine: return false
        case .moveUp, .moveDown, .moveLeft, .moveRight: return Defaults.resizeOnDirectionalMove.enabled
        default: return true
        }
    }
    
    var allowedToExtendOutsideCurrentScreenArea: Bool {
        switch self {
        case .doubleHeightUp, .doubleHeightDown, .doubleWidthLeft, .doubleWidthRight:
            return true
        default:
            return false
        }
    }
    
    var isDragSnappable: Bool {
        switch self {
        case .restore, .previousDisplay, .nextDisplay, .moveUp, .moveDown, .moveLeft, .moveRight, .gridMoveLeft, .gridMoveRight, .gridMoveUp, .gridMoveDown, .gridSpanLeft, .gridSpanRight, .gridSpanUp, .gridSpanDown, .activateLayoutSlot1, .activateLayoutSlot2, .activateLayoutSlot3, .activateLayoutSlot4, .activateLayoutSlot5, .activateLayoutSlot6, .activateLayoutSlot7, .activateLayoutSlot8, .activateLayoutSlot9, .specified, .reverseAll, .tileAll, .cascadeAll, .larger, .smaller, .largerWidth, .smallerWidth, .cascadeActiveApp, .tileActiveApp, .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive, .displaySix, .displaySeven, .displayEight, .displayNine:
            return false
        default:
            return true
        }
    }

    var spectacleDefault: Shortcut? {
        switch self {
        case .leftHalf: return Shortcut( cmd|alt, kVK_LeftArrow )
        case .rightHalf: return Shortcut( cmd|alt, kVK_RightArrow )
        case .maximize: return Shortcut( cmd|alt, kVK_ANSI_F )
        case .maximizeHeight: return Shortcut( ctrl|alt|shift, kVK_UpArrow )
        case .previousDisplay: return Shortcut( ctrl|alt|cmd, kVK_LeftArrow )
        case .nextDisplay:  return Shortcut( ctrl|alt|cmd, kVK_RightArrow )
        case .larger: return Shortcut( ctrl|alt|shift, kVK_RightArrow )
        case .smaller: return Shortcut( ctrl|alt|shift, kVK_LeftArrow )
        case .bottomHalf: return Shortcut( cmd|alt, kVK_DownArrow )
        case .topHalf: return Shortcut( cmd|alt, kVK_UpArrow )
        case .center: return Shortcut( alt|cmd, kVK_ANSI_C )
        // bottomLeft/bottomRight previously claimed cmd|ctrl|shift+Left/Right. Those
        // chords are freed here (return nil) so the Lilypad grid SPAN actions
        // (gridSpanLeft/Right, below) can use cmd|ctrl|shift+arrow as their default.
        // The actions stay fully defined and remain rebindable in the settings UI.
        case .bottomLeft: return nil
        case .bottomRight: return nil
        case .topLeft: return Shortcut( ctrl|cmd, kVK_LeftArrow )
        case .topRight: return Shortcut( ctrl|cmd, kVK_RightArrow )
        case .restore: return Shortcut( ctrl|alt, kVK_Delete)
        // Grid keyboard nav (M7). Command+Shift+arrow (user preference). NOTE: these are
        // the system text-selection shortcuts, so as a global hotkey they override
        // select-to-line/document in editors; rebindable in the M14 settings UI.
        case .gridMoveLeft: return Shortcut( cmd|shift, kVK_LeftArrow )
        case .gridMoveRight: return Shortcut( cmd|shift, kVK_RightArrow )
        case .gridMoveUp: return Shortcut( cmd|shift, kVK_UpArrow )
        case .gridMoveDown: return Shortcut( cmd|shift, kVK_DownArrow )
        // Grid keyboard SPAN (M8a). Command+Control+Shift+arrow (user preference) —
        // grows the focused window's grid footprint by one zone-line. The Left/Right
        // chords were freed above by nil'ing bottomLeft/bottomRight; Up/Down were
        // unused (maximizeHeight uses ctrl|alt|shift+Up, no cmd).
        case .gridSpanLeft: return Shortcut( cmd|ctrl|shift, kVK_LeftArrow )
        case .gridSpanRight: return Shortcut( cmd|ctrl|shift, kVK_RightArrow )
        case .gridSpanUp: return Shortcut( cmd|ctrl|shift, kVK_UpArrow )
        case .gridSpanDown: return Shortcut( cmd|ctrl|shift, kVK_DownArrow )
        // Monitor-relative layout activation (M9). Control+Command+digit — verified free
        // across the repo (no action or default uses ctrl|cmd with a digit; ctrl|cmd is
        // otherwise only arrow chords) and Option-FREE (the user's keyboard has no Option
        // key). Rebindable in the M14 settings UI.
        case .activateLayoutSlot1: return Shortcut( ctrl|cmd, kVK_ANSI_1 )
        case .activateLayoutSlot2: return Shortcut( ctrl|cmd, kVK_ANSI_2 )
        case .activateLayoutSlot3: return Shortcut( ctrl|cmd, kVK_ANSI_3 )
        case .activateLayoutSlot4: return Shortcut( ctrl|cmd, kVK_ANSI_4 )
        case .activateLayoutSlot5: return Shortcut( ctrl|cmd, kVK_ANSI_5 )
        case .activateLayoutSlot6: return Shortcut( ctrl|cmd, kVK_ANSI_6 )
        case .activateLayoutSlot7: return Shortcut( ctrl|cmd, kVK_ANSI_7 )
        case .activateLayoutSlot8: return Shortcut( ctrl|cmd, kVK_ANSI_8 )
        case .activateLayoutSlot9: return Shortcut( ctrl|cmd, kVK_ANSI_9 )
        default: return nil
        }
    }

    var alternateDefault: Shortcut? {
        switch self {
        case .leftHalf: return Shortcut( ctrl|alt, kVK_LeftArrow )
        case .rightHalf: return Shortcut( ctrl|alt, kVK_RightArrow )
        case .bottomHalf: return Shortcut( ctrl|alt, kVK_DownArrow )
        case .topHalf: return Shortcut( ctrl|alt, kVK_UpArrow )
        case .bottomLeft: return Shortcut( ctrl|alt, kVK_ANSI_J )
        case .bottomRight: return Shortcut( ctrl|alt, kVK_ANSI_K )
        case .topLeft: return Shortcut( ctrl|alt, kVK_ANSI_U )
        case .topRight: return Shortcut( ctrl|alt, kVK_ANSI_I )
        case .maximize: return Shortcut( ctrl|alt, kVK_Return )
        case .maximizeHeight: return Shortcut( ctrl|alt|shift, kVK_UpArrow )
        case .previousDisplay: return Shortcut( ctrl|alt|cmd, kVK_LeftArrow )
        case .nextDisplay: return Shortcut( ctrl|alt|cmd, kVK_RightArrow )
        case .larger: return Shortcut( ctrl|alt, kVK_ANSI_Equal )
        case .smaller: return Shortcut( ctrl|alt, kVK_ANSI_Minus )
        case .center: return Shortcut( ctrl|alt, kVK_ANSI_C )
        case .restore: return Shortcut( ctrl|alt, kVK_Delete)
        case .firstThird: return Shortcut( ctrl|alt, kVK_ANSI_D )
        case .firstTwoThirds: return Shortcut( ctrl|alt, kVK_ANSI_E )
        case .centerThird: return Shortcut( ctrl|alt, kVK_ANSI_F )
        case .lastTwoThirds: return Shortcut( ctrl|alt, kVK_ANSI_T )
        case .lastThird: return Shortcut( ctrl|alt, kVK_ANSI_G )
        case .centerTwoThirds:
            if let installVersion = Defaults.installVersion.value,
               let intInstallVersion = Int(installVersion),
               intInstallVersion > 94 {
                return Shortcut( ctrl|alt, kVK_ANSI_R )
            }
            return nil
        case .gridMoveLeft: return Shortcut( cmd|shift, kVK_LeftArrow )
        case .gridMoveRight: return Shortcut( cmd|shift, kVK_RightArrow )
        case .gridMoveUp: return Shortcut( cmd|shift, kVK_UpArrow )
        case .gridMoveDown: return Shortcut( cmd|shift, kVK_DownArrow )
        // Grid keyboard SPAN (M8a): cmd|ctrl|shift+arrow in both default tables.
        case .gridSpanLeft: return Shortcut( cmd|ctrl|shift, kVK_LeftArrow )
        case .gridSpanRight: return Shortcut( cmd|ctrl|shift, kVK_RightArrow )
        case .gridSpanUp: return Shortcut( cmd|ctrl|shift, kVK_UpArrow )
        case .gridSpanDown: return Shortcut( cmd|ctrl|shift, kVK_DownArrow )
        // Monitor-relative layout activation (M9): Control+Command+digit in both default
        // tables (Option-free, verified free across the repo).
        case .activateLayoutSlot1: return Shortcut( ctrl|cmd, kVK_ANSI_1 )
        case .activateLayoutSlot2: return Shortcut( ctrl|cmd, kVK_ANSI_2 )
        case .activateLayoutSlot3: return Shortcut( ctrl|cmd, kVK_ANSI_3 )
        case .activateLayoutSlot4: return Shortcut( ctrl|cmd, kVK_ANSI_4 )
        case .activateLayoutSlot5: return Shortcut( ctrl|cmd, kVK_ANSI_5 )
        case .activateLayoutSlot6: return Shortcut( ctrl|cmd, kVK_ANSI_6 )
        case .activateLayoutSlot7: return Shortcut( ctrl|cmd, kVK_ANSI_7 )
        case .activateLayoutSlot8: return Shortcut( ctrl|cmd, kVK_ANSI_8 )
        case .activateLayoutSlot9: return Shortcut( ctrl|cmd, kVK_ANSI_9 )
        default: return nil
        }
    }

    var image: NSImage {
        switch self {
        case .leftHalf: return NSImage(imageLiteralResourceName: "leftHalfTemplate")
        case .rightHalf: return NSImage(imageLiteralResourceName: "rightHalfTemplate")
        case .maximize: return NSImage(imageLiteralResourceName: "maximizeTemplate")
        case .maximizeHeight: return NSImage(imageLiteralResourceName: "maximizeHeightTemplate")
        case .previousDisplay: return NSImage(imageLiteralResourceName: "prevDisplayTemplate")
        case .nextDisplay: return NSImage(imageLiteralResourceName: "nextDisplayTemplate")
        case .larger: return NSImage(imageLiteralResourceName: "makeLargerTemplate")
        case .smaller: return NSImage(imageLiteralResourceName: "makeSmallerTemplate")
        case .bottomHalf: return NSImage(imageLiteralResourceName: "bottomHalfTemplate")
        case .topHalf: return NSImage(imageLiteralResourceName: "topHalfTemplate")
        case .center: return NSImage(imageLiteralResourceName: "centerTemplate")
        case .bottomLeft: return NSImage(imageLiteralResourceName: "bottomLeftTemplate")
        case .bottomRight: return NSImage(imageLiteralResourceName: "bottomRightTemplate")
        case .topLeft: return NSImage(imageLiteralResourceName: "topLeftTemplate")
        case .topRight: return NSImage(imageLiteralResourceName: "topRightTemplate")
        case .restore: return NSImage(imageLiteralResourceName: "restoreTemplate")
        case .firstThird: return NSImage(imageLiteralResourceName: "firstThirdTemplate")
        case .firstTwoThirds: return NSImage(imageLiteralResourceName: "firstTwoThirdsTemplate")
        case .centerThird: return NSImage(imageLiteralResourceName: "centerThirdTemplate")
        case .centerTwoThirds: return NSImage(imageLiteralResourceName: "centerTwoThirdsTemplate")
        case .lastTwoThirds: return NSImage(imageLiteralResourceName: "lastTwoThirdsTemplate")
        case .lastThird: return NSImage(imageLiteralResourceName: "lastThirdTemplate")
        case .moveLeft: return NSImage(imageLiteralResourceName: "moveLeftTemplate")
        case .moveRight: return NSImage(imageLiteralResourceName: "moveRightTemplate")
        case .moveUp: return NSImage(imageLiteralResourceName: "moveUpTemplate")
        case .moveDown: return NSImage(imageLiteralResourceName: "moveDownTemplate")
        case .almostMaximize: return NSImage(imageLiteralResourceName: "almostMaximizeTemplate")
        case .centerHalf: return NSImage(imageLiteralResourceName: "halfWidthCenterTemplate")
        case .firstFourth: return NSImage(imageLiteralResourceName: "leftFourthTemplate")
        case .secondFourth: return NSImage(imageLiteralResourceName: "centerLeftFourthTemplate")
        case .thirdFourth: return NSImage(imageLiteralResourceName: "centerRightFourthTemplate")
        case .lastFourth: return NSImage(imageLiteralResourceName: "rightFourthTemplate")
        case .firstThreeFourths: return NSImage(imageLiteralResourceName: "firstThreeFourthsTemplate")
        case .centerThreeFourths: return NSImage(imageLiteralResourceName: "centerThreeFourthsTemplate")
        case .lastThreeFourths: return NSImage(imageLiteralResourceName: "lastThreeFourthsTemplate")
        case .doubleHeightUp: return  NSImage()
        case .doubleHeightDown: return  NSImage()
        case .doubleWidthLeft: return  NSImage()
        case .doubleWidthRight: return  NSImage()
        case .halveHeightUp: return  NSImage()
        case .halveHeightDown: return  NSImage()
        case .halveWidthLeft: return  NSImage()
        case .halveWidthRight: return  NSImage()
        case .specified, .reverseAll: return NSImage()
        case .tileAll: return NSImage()
        case .cascadeAll: return NSImage()
        case .leftTodo: return NSImage()
        case .rightTodo: return NSImage()
        case .cascadeActiveApp: return NSImage()
        case .tileActiveApp: return NSImage()
        case .centerProminently: return NSImage()
        case .largerWidth: return NSImage(imageLiteralResourceName: "largerWidthTemplate")
        case .smallerWidth: return NSImage(imageLiteralResourceName: "smallerWidthTemplate")
        case .largerHeight: return NSImage()
        case .smallerHeight: return NSImage()
        case .topVerticalThird: return NSImage(imageLiteralResourceName: "topThirdTemplate")
        case .middleVerticalThird: return NSImage(imageLiteralResourceName: "centerThirdHorizontalTemplate")
        case .bottomVerticalThird: return NSImage(imageLiteralResourceName: "bottomThirdTemplate")
        case .topVerticalTwoThirds: return NSImage(imageLiteralResourceName: "topTwoThirdsTemplate")
        case .bottomVerticalTwoThirds: return NSImage(imageLiteralResourceName: "bottomTwoThirdsTemplate")
        case .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive,
             .displaySix, .displaySeven, .displayEight, .displayNine:
            return NSImage(imageLiteralResourceName: "nextDisplayTemplate")
        case .gridMoveLeft: return NSImage(imageLiteralResourceName: "moveLeftTemplate")
        case .gridMoveRight: return NSImage(imageLiteralResourceName: "moveRightTemplate")
        case .gridMoveUp: return NSImage(imageLiteralResourceName: "moveUpTemplate")
        case .gridMoveDown: return NSImage(imageLiteralResourceName: "moveDownTemplate")
        case .gridSpanLeft: return NSImage(imageLiteralResourceName: "moveLeftTemplate")
        case .gridSpanRight: return NSImage(imageLiteralResourceName: "moveRightTemplate")
        case .gridSpanUp: return NSImage(imageLiteralResourceName: "moveUpTemplate")
        case .gridSpanDown: return NSImage(imageLiteralResourceName: "moveDownTemplate")
        case .activateLayoutSlot1, .activateLayoutSlot2, .activateLayoutSlot3, .activateLayoutSlot4, .activateLayoutSlot5,
             .activateLayoutSlot6, .activateLayoutSlot7, .activateLayoutSlot8, .activateLayoutSlot9:
            return NSImage()
        }
    }

    var gapSharedEdge: Edge {
        switch self {
        case .leftHalf: return .right
        case .rightHalf: return .left
        case .bottomHalf: return .top
        case .topHalf: return .bottom
        case .bottomLeft: return [.top, .right]
        case .bottomRight: return [.top, .left]
        case .topLeft: return [.bottom, .right]
        case .topRight: return [.bottom, .left]
        case .moveUp: return Defaults.resizeOnDirectionalMove.enabled ? .bottom : .none
        case .moveDown: return Defaults.resizeOnDirectionalMove.enabled ? .top : .none
        case .moveLeft: return Defaults.resizeOnDirectionalMove.enabled ? .right : .none
        case .moveRight: return Defaults.resizeOnDirectionalMove.enabled ? .left : .none
        default:
            return .none
        }
    }

    var gapsApplicable: Dimension {
        switch self {
        case .leftHalf, .rightHalf, .bottomHalf, .topHalf, .centerHalf, .bottomLeft, .bottomRight, .topLeft, .topRight, .firstThird, .firstTwoThirds, .centerThird, .centerTwoThirds, .lastTwoThirds, .lastThird, .firstFourth, .secondFourth, .thirdFourth, .lastFourth, .firstThreeFourths, .centerThreeFourths, .lastThreeFourths, .doubleHeightUp, .doubleHeightDown, .doubleWidthLeft, .doubleWidthRight, .halveHeightUp, .halveHeightDown, .halveWidthLeft, .halveWidthRight, .leftTodo, .rightTodo, .topVerticalThird, .middleVerticalThird, .bottomVerticalThird, .topVerticalTwoThirds, .bottomVerticalTwoThirds:
            return .both
        case .moveUp, .moveDown:
            return Defaults.resizeOnDirectionalMove.enabled ? .vertical : .none;
        case .moveLeft, .moveRight:
            return Defaults.resizeOnDirectionalMove.enabled ? .horizontal : .none;
        case .maximize:
            return Defaults.applyGapsToMaximize.userDisabled ? .none : .both;
        case .maximizeHeight:
            return Defaults.applyGapsToMaximizeHeight.userDisabled ? .none : .vertical;
        case .almostMaximize, .previousDisplay, .nextDisplay, .larger, .smaller, .largerWidth, .smallerWidth, .largerHeight, .smallerHeight, .center, .centerProminently, .restore, .specified, .reverseAll, .tileAll, .cascadeAll, .cascadeActiveApp, .tileActiveApp,
             .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive,
             .displaySix, .displaySeven, .displayEight, .displayNine,
             // Grid keyboard nav + span: intercepted before WindowManager.execute, so
             // gaps are applied by GridLayoutManager (zoneRectWithGaps/rangeRectWithGaps),
             // not this path.
             .gridMoveLeft, .gridMoveRight, .gridMoveUp, .gridMoveDown,
             .gridSpanLeft, .gridSpanRight, .gridSpanUp, .gridSpanDown,
             // Layout-activation slots: intercepted by GridLayoutManager, never reach
             // the calculation/gap path.
             .activateLayoutSlot1, .activateLayoutSlot2, .activateLayoutSlot3, .activateLayoutSlot4, .activateLayoutSlot5,
             .activateLayoutSlot6, .activateLayoutSlot7, .activateLayoutSlot8, .activateLayoutSlot9:
            return .none
        }
    }

    var category: WindowActionCategory? { // used to specify a submenu
        switch self {
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds, .lastTwoThirds: return .thirds
        case .firstFourth, .secondFourth, .thirdFourth, .lastFourth, .firstThreeFourths, .centerThreeFourths, .lastThreeFourths: return .fourths
        case .moveUp, .moveDown, .moveLeft, .moveRight, .gridMoveLeft, .gridMoveRight, .gridMoveUp, .gridMoveDown, .gridSpanLeft, .gridSpanRight, .gridSpanUp, .gridSpanDown: return .move
        case .almostMaximize, .maximizeHeight, .larger, .smaller, .largerWidth, .smallerWidth, .largerHeight, .smallerHeight: return .size
        default: return nil
        }
    }

    var classification: WindowActionCategory? {
        switch self {
        case .firstThird, .firstTwoThirds, .centerThird, .centerTwoThirds, .lastTwoThirds, .lastThird:
            return .thirds
        case .smaller, .larger, .smallerWidth, .largerWidth, .smallerHeight, .largerHeight:
            return .size
        case .previousDisplay, .nextDisplay,
             .displayOne, .displayTwo, .displayThree, .displayFour, .displayFive,
             .displaySix, .displaySeven, .displayEight, .displayNine:
            return .display
        default: return nil
        }
    }
}

enum SubWindowAction {
    case leftThird,
    centerVerticalThird,
    rightThird,
    leftTwoThirds,
    rightTwoThirds,
    
    topThird,
    centerHorizontalThird,
    bottomThird,
    topTwoThirds,
    bottomTwoThirds,
    
    leftFourth,
    centerLeftFourth,
    centerRightFourth,
    rightFourth,
    
    topFourth,
    centerTopFourth,
    centerBottomFourth,
    bottomFourth,
    
    rightThreeFourths,
    bottomThreeFourths,
    leftThreeFourths,
    topThreeFourths,
    centerVerticalThreeFourths,
    centerHorizontalThreeFourths,
    
    centerVerticalHalf,
    centerHorizontalHalf,
    
    
    
    
    
         

    topLeftQuarter,
    topRightQuarter,
    bottomLeftQuarter,
    bottomRightQuarter,




    maximize,
    
    leftTodo,
    rightTodo

    var gapSharedEdge: Edge {
        switch self {
        case .leftThird: return .right
        case .centerVerticalThird: return [.right, .left]
        case .rightThird: return .left
        case .leftTwoThirds: return .right
        case .rightTwoThirds: return .left
        case .topThird: return .bottom
        case .centerHorizontalThird: return [.top, .bottom]
        case .bottomThird: return .top
        case .topTwoThirds: return .bottom
        case .bottomTwoThirds: return .top
        case .leftFourth: return .right
        case .centerLeftFourth: return [.right, .left]
        case .centerRightFourth: return [.right, .left]
        case .rightFourth: return .left
        case .topFourth: return .bottom
        case .centerTopFourth: return [.top, .bottom]
        case .centerBottomFourth: return [.top, .bottom]
        case .bottomFourth: return .top
        case .rightThreeFourths: return .left
        case .bottomThreeFourths: return .top
        case .leftThreeFourths: return .right
        case .topThreeFourths: return .bottom
        case .centerVerticalThreeFourths: return [.right, .left]
        case .centerHorizontalThreeFourths: return [.top, .bottom]
        case .centerVerticalHalf: return [.right, .left]
        case .centerHorizontalHalf: return [.top, .bottom]
        case .topLeftQuarter: return [.right, .bottom]
        case .topRightQuarter: return [.left, .bottom]
        case .bottomLeftQuarter: return [.right, .top]
        case .bottomRightQuarter: return [.left, .top]
        case .maximize: return .none
        case .leftTodo: return .right
        case .rightTodo: return .left
        }
    }
}

struct Shortcut: Codable {
    let keyCode: Int
    let modifierFlags: UInt
    
    init(_ modifierFlags: UInt, _ keyCode: Int) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }
    
    init(masShortcut: MASShortcut) {
        self.keyCode = masShortcut.keyCode
        self.modifierFlags = masShortcut.modifierFlags.rawValue
    }
    
    func toMASSHortcut() -> MASShortcut {
        MASShortcut(keyCode: keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: modifierFlags))
    }
    
    func displayString() -> String {
        let masShortcut = toMASSHortcut()
        return masShortcut.modifierFlagsString + (masShortcut.keyCodeString ?? "")
    }
}
