//
//  PickerManager.swift
//  AnyImageKit
//
//  Created by 刘栋 on 2019/9/16.
//  Copyright © 2019-2021 AnyImageProject.org. All rights reserved.
//

import UIKit
import Photos

struct FetchRecord {
    
    let identifier: String
    var requestIDs: [PHImageRequestID]
}

final class PickerManager {
    
    var options: PickerOptionsInfo = .init()
    
    var isUpToLimit: Bool {
        return selectedAssets.count == options.selectLimit
    }
    
    var useOriginalImage: Bool = false
    
    /// 已选中的资源
    private(set) var selectedAssets: [PhotoAsset] = []
    /// 获取失败的资源
    private var failedAssets: [PhotoAsset] = []
    /// 管理 failedAssets 队列的锁
    private let lock: NSLock = .init()
    
    /// Running Fetch Requests
    private var fetchRecords = [FetchRecord]()
    
    /// 缓存
    let cache = ImageCacheTool(module: .picker(.default), memoryCountLimit: 10, useDiskCache: false)
    
    init() { }
    
    let workQueue = DispatchQueue(label: "org.AnyImageProject.AnyImageKit.DispatchQueue.PickerManager")
    let resizeSemaphore = DispatchSemaphore(value: 3)
}

extension PickerManager {
    
    func clearAll() {
        useOriginalImage = false
        selectedAssets.removeAll()
        failedAssets.removeAll()
        cache.clearAll()
        cancelAllFetch()
    }
}

// MARK: - Fetch Queue

extension PickerManager {
    
    func enqueueFetch(for identifier: String, requestID: PHImageRequestID) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            if let index = self.fetchRecords.firstIndex(where: { $0.identifier == identifier }) {
                self.fetchRecords[index].requestIDs.append(requestID)
            } else {
                self.fetchRecords.append(FetchRecord(identifier: identifier, requestIDs: [requestID]))
            }
        }
    }
    
    func dequeueFetch(for identifier: String, requestID: PHImageRequestID?) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            guard let requestID = requestID else { return }
            if let index = self.fetchRecords.firstIndex(where: { $0.identifier == identifier }) {
                if let idx = self.fetchRecords[index].requestIDs.firstIndex(of: requestID) {
                    self.fetchRecords[index].requestIDs.remove(at: idx)
                }
                if self.fetchRecords[index].requestIDs.isEmpty {
                    self.fetchRecords.remove(at: index)
                }
            }
        }
    }
    
    func cancelFetch(for identifier: String) {
        if let index = self.fetchRecords.firstIndex(where: { $0.identifier == identifier }) {
            let fetchRecord = self.fetchRecords.remove(at: index)
            fetchRecord.requestIDs.forEach { PHImageManager.default().cancelImageRequest($0) }
        }
    }
    
    func cancelAllFetch() {
        for fetchRecord in self.fetchRecords {
            fetchRecord.requestIDs.forEach { PHImageManager.default().cancelImageRequest($0) }
        }
        self.fetchRecords.removeAll()
    }
}

// MARK: - Select

extension PickerManager {
    
    @discardableResult
    func addSelectedAsset(_ asset: PhotoAsset) -> Bool {
        if selectedAssets.contains(asset) { return false }
        if selectedAssets.count == options.selectLimit { return false }
        selectedAssets.append(asset)
        asset.isSelected = true
        asset.selectedNum = selectedAssets.count
        syncAsset(asset)
        return true
    }
    
    @discardableResult
    func removeSelectedAsset(_ asset: PhotoAsset) -> Bool {
        guard let idx = selectedAssets.firstIndex(where: { $0 == asset }) else { return false }
        for item in selectedAssets {
            if item.selectedNum > asset.selectedNum {
                item.selectedNum -= 1
            }
        }
        selectedAssets.remove(at: idx)
        asset.isSelected = false
        asset._images[.initial] = nil
        return true
    }
    
    func removeAllSelectedAsset() {
        selectedAssets.removeAll()
    }
    
    func syncAsset(_ asset: PhotoAsset) {
        switch asset.mediaType {
        case .photo, .photoGIF, .photoLive:
            // 勾选图片就开始加载
            if let image = cache.retrieveImage(forKey: asset.identifier) {
                asset._images[.initial] = image
                self.didSyncAsset()
            } else {
                workQueue.async { [weak self] in
                    guard let self = self else { return }
                    let options = _PhotoFetchOptions(sizeMode: .preview(self.options.largePhotoMaxWidth))
                    self.requestPhoto(for: asset.phAsset, options: options) { result in
                        switch result {
                        case .success(let response):
                            if !response.isDegraded {
                                asset._images[.initial] = response.image
                                self.didSyncAsset()
                            }
                        case .failure(let error):
                            self.lock.lock()
                            self.failedAssets.append(asset)
                            self.lock.unlock()
                            _print(error)
                            let message = BundleHelper.localizedString(key: "FETCH_FAILED_PLEASE_RETRY", module: .picker)
                            NotificationCenter.default.post(name: .didSyncAsset, object: message)
                        }
                    }
                }
            }
        case .video:
            workQueue.async { [weak self] in
                guard let self = self else { return }
                let options = _PhotoFetchOptions(sizeMode: .preview(500), needCache: true)
                self.requestPhoto(for: asset.phAsset, options: options, completion: { result in
                    switch result {
                    case .success(let response):
                        asset._images[.initial] = response.image
                    case .failure:
                        break
                    }
                })
                // 同步请求图片
                self.requestVideo(for: asset.phAsset) { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case .success(_):
                        asset.videoDidDownload = true
                        self.didSyncAsset()
                    case .failure(let error):
                        self.lock.lock()
                        self.failedAssets.append(asset)
                        self.lock.unlock()
                        _print(error)
                        let message = BundleHelper.localizedString(key: "FETCH_FAILED_PLEASE_RETRY", module: .picker)
                        NotificationCenter.default.post(name: .didSyncAsset, object: message)
                    }
                }
            }
        }
    }
    
    func resynchronizeAsset() {
        lock.lock()
        let assets = failedAssets
        failedAssets.removeAll()
        lock.unlock()
        assets.forEach { syncAsset($0) }
    }
}

// MARK: - Private function
extension PickerManager {
    
    private func didSyncAsset() {
        let isReady = selectedAssets.filter{ !$0.isReady }.isEmpty
        if isReady {
            NotificationCenter.default.post(name: .didSyncAsset, object: nil)
        }
    }
}
