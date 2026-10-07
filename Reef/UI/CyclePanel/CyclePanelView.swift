//
//  CyclePanelView.swift
//  Reef
//
//  Window switcher panel UI
//

import AppKit
import SwiftUI

struct CyclePanelView: View {
    @ObservedObject var state: CyclePanelState
    var onHoverIndex: (Int) -> Void = { _ in }
    var onHoverEnd: (Int) -> Void = { _ in }
    var onActivateIndex: (Int) -> Void = { _ in }

    private let headerPadding: Double = 12
    private let maxNonScrollingRows: Int = 5
    
    private func itemTitle(_ item: CyclePanelItem) -> String {
        switch item {
        case .window(let window):
            return window.title
        case .action(let action):
            return action.title
        case .app(let application):
            return application.title
        }
    }

    private func itemIcon(_ item: CyclePanelItem) -> NSImage? {
        switch item {
        case .app(let application):
            return application.icon
        case .window, .action:
            return nil
        }
    }

    @ViewBuilder
    private func rows() -> some View {
        ForEach(Array(state.items.enumerated()), id: \.offset) { index, item in
            CyclePanelRow(
                title: itemTitle(item),
                icon: itemIcon(item),
                isSelected: index == state.selectedIndex
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    onHoverIndex(index)
                } else {
                    onHoverEnd(index)
                }
            }
            .onTapGesture {
                onActivateIndex(index)
            }
            .id(index)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text(state.applicationTitle)
                .font(.headline)
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.vertical, headerPadding)

            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Window list
            if state.items.count <= maxNonScrollingRows {
                VStack(spacing: 4) {
                    rows()
                }
                .padding(8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 4) {
                            rows()
                        }
                        .padding(8)
                    }
                    .onChange(of: state.keyboardSelectionGeneration) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(state.selectedIndex, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 400)
        .background(Color.clear)
    }
}

struct CyclePanelRow: View {
    let title: String
    var icon: NSImage? = nil
    let isSelected: Bool

    private let rowHeight: CGFloat = 44
    private let iconSize: CGFloat = 22
    
    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator
            Circle()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 6, height: 6)
            
            HStack(spacing: 8) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: iconSize, height: iconSize)
                }
                
                Text(title)
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
            
        )
    }
}
