import { common } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { image } from '@kit.ImageKit'
import fs from '@ohos.file.fs'
import window from '@ohos.window'
import { Catalog, SurfaceController, SurfaceEventType, UIRendererComponent, SurfaceControllerFactory,
  CatalogFactory } from '@arkui-genius/genui'

const CASE_INPUT_DIR: string = 'a2ui_cases'
const SHOT_OUTPUT_DIR: string = 'a2ui-render-shots'
const RENDER_STABLE_DELAY_MS: number = 1000
const CASE_GAP_DELAY_MS: number = 120
const MESSAGE_FEED_DELAY_MS: number = 120

interface RenderCase {
  name: string
  rawfilePath: string
}

interface RenderResult {
  name: string
  outputPath: string
  success: boolean
  error: string
}

@Entry
@Component
struct Index {
  @State controller: SurfaceController | null = null
  @State cases: RenderCase[] = []
  @State results: RenderResult[] = []
  @State currentCaseName: string = ''
  @State statusText: string = 'Waiting'
  @State outputDir: string = ''
  @State captureMode: boolean = true

  private context: common.Context | null = null
  private stopped: boolean = false

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.Context
    this.outputDir = `${this.context.filesDir}/${SHOT_OUTPUT_DIR}`
    this.startBatchRender()
  }

  aboutToDisappear(): void {
    this.stopped = true
    this.destroyController()
  }

  private async startBatchRender(): Promise<void> {
    const context = this.context
    if (context === null) {
      this.statusText = 'Host context unavailable'
      return
    }

    this.statusText = 'Loading cases'
    this.ensureOutputDir(this.outputDir)
    this.cases = await this.loadRenderCases(context)

    if (this.cases.length === 0) {
      this.statusText = `No .json/.jsonl files found in rawfile/${CASE_INPUT_DIR}`
      return
    }

    this.results = []
    this.captureMode = true
    for (let index = 0; index < this.cases.length; index++) {
      if (this.stopped) {
        return
      }

      const item = this.cases[index]
      this.currentCaseName = item.name
      this.statusText = `Rendering ${index + 1}/${this.cases.length}`
      const result = await this.renderCase(context, item)
      this.results = this.results.concat([result])
      await this.sleep(CASE_GAP_DELAY_MS)
    }

    this.currentCaseName = ''
    this.statusText = `Done: ${this.successCount()}/${this.results.length} screenshots saved`
    this.captureMode = false
  }

  private async loadRenderCases(context: common.Context): Promise<RenderCase[]> {
    try {
      const files = await context.resourceManager.getRawFileList(CASE_INPUT_DIR)
      const renderCases: RenderCase[] = []

      files.forEach((fileName: string) => {
        if (this.isJsonCaseFile(fileName)) {
          renderCases.push({
            name: fileName,
            rawfilePath: `${CASE_INPUT_DIR}/${fileName}`
          })
        }
      })

      renderCases.sort((left: RenderCase, right: RenderCase) => left.name.localeCompare(right.name))
      return renderCases
    } catch (error) {
      console.error(`Failed to list rawfile/${CASE_INPUT_DIR}: ${error}`)
      return []
    }
  }

  private async renderCase(context: common.Context, item: RenderCase): Promise<RenderResult> {
    const outputPath = `${this.outputDir}/${this.toSafeBaseName(item.name)}.png`

    try {
      const messages = this.loadMessages(context, item.rawfilePath)
      if (messages.length === 0) {
        return this.failedResult(item.name, outputPath, 'No render messages parsed')
      }

      this.destroyController()
      await this.sleep(CASE_GAP_DELAY_MS)
      this.controller = this.createController()
      await this.sleep(CASE_GAP_DELAY_MS)

      for (const message of messages) {
        this.controller?.handleMessage(message)
        await this.sleep(MESSAGE_FEED_DELAY_MS)
      }

      await this.sleep(RENDER_STABLE_DELAY_MS)
      await this.captureRender(outputPath)
      console.info(`Saved A2UI screenshot: ${outputPath}`)

      return {
        name: item.name,
        outputPath: outputPath,
        success: true,
        error: ''
      }
    } catch (error) {
      console.error(`Failed to render ${item.name}: ${error}`)
      return this.failedResult(item.name, outputPath, `${error}`)
    }
  }

  private createController(): SurfaceController {
    const callback = (eventType: SurfaceEventType, _ctrl: SurfaceController) => {
      console.info(`A2UI surface event: ${eventType}`)
    }
    // const controller = new SurfaceController(Catalog.extended(), callback)
    const controller = SurfaceControllerFactory.createSurfaceController({uiContext: this.getUIContext(), catalog: CatalogFactory.extended(), eventCallback: callback})
    controller.registerActionReceiver((action: string) => {
      console.info(`Action received: ${action}`)
    })
    return controller
  }

  private destroyController(): void {
    this.controller?.destroy()
    this.controller = null
  }

  private loadMessages(context: common.Context, rawfilePath: string): string[] {
    const fileData = context.resourceManager.getRawFileContentSync(rawfilePath)
    const decoderOptions: util.TextDecoderOptions = {
      fatal: false,
      ignoreBOM: true
    }
    const decodeOptions: util.DecodeToStringOptions = {
      stream: false
    }
    const textDecoder = util.TextDecoder.create('utf-8', decoderOptions)
    const jsonText = textDecoder.decodeToString(fileData, decodeOptions)
    const trimmedText = jsonText.trim()
    if (trimmedText.length === 0) {
      return []
    }

    if (trimmedText.startsWith('[')) {
      let parsed: Object[] | string[] = []
      try {
        parsed = JSON.parse(trimmedText) as Object[] | string[]
      } catch (error) {
        throw new Error(`Invalid JSON array in ${rawfilePath}: ${error}`)
      }

      if (!Array.isArray(parsed)) {
        return []
      }

      return parsed.map((message: Object | string): string => {
        if (typeof message === 'string') {
          return message
        }
        return JSON.stringify(message)
      })
    }

    const messages: string[] = []
    const lines = trimmedText.split(/\r?\n/)
    for (let index = 0; index < lines.length; index++) {
      const line = lines[index].trim()
      if (line.length === 0) {
        continue
      }

      try {
        JSON.parse(line)
      } catch (error) {
        throw new Error(`Invalid JSONL line ${index + 1} in ${rawfilePath}: ${error}`)
      }

      messages.push(line)
    }
    return messages
  }

  private async captureRender(outputPath: string): Promise<void> {
    const context = this.context
    if (context === null) {
      throw new Error('Host context unavailable')
    }

    this.ensureOutputDir(this.outputDir)
    const mainWindow = await window.getLastWindow(context)
    const pixelMap = await mainWindow.snapshot()
    const packer = image.createImagePacker()
    const options: image.PackingOption = {
      format: 'image/png',
      quality: 100
    }
    let file: fs.File | null = null

    try {
      const imageBuffer = await packer.packToData(pixelMap, options)
      file = fs.openSync(outputPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, imageBuffer)
    } finally {
      if (file !== null) {
        fs.closeSync(file)
      }
      pixelMap.release()
      packer.release()
    }
  }

  private ensureOutputDir(path: string): void {
    try {
      if (!fs.accessSync(path)) {
        fs.mkdirSync(path, true)
      }
    } catch (_error) {
      fs.mkdirSync(path, true)
    }
  }

  private failedResult(name: string, outputPath: string, error: string): RenderResult {
    return {
      name: name,
      outputPath: outputPath,
      success: false,
      error: error
    }
  }

  private isJsonCaseFile(fileName: string): boolean {
    return fileName.endsWith('.jsonl') || fileName.endsWith('.json')
  }

  private toSafeBaseName(fileName: string): string {
    const dotIndex = fileName.lastIndexOf('.')
    const baseName = dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName
    return baseName.replace(/[^a-zA-Z0-9_-]/g, '_')
  }

  private successCount(): number {
    return this.results.filter((item: RenderResult) => item.success).length
  }

  private sleep(delayMs: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, delayMs)
    })
  }

  build() {
    Column() {
      if (this.captureMode) {
        if (this.controller !== null) {
          UIRendererComponent({ surfaceController: this.controller })
        }
      } else {
        if (this.controller !== null) {
          UIRendererComponent({ surfaceController: this.controller })
        }

        Column({ space: 8 }) {
          Text(this.statusText)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#202124')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(this.currentCaseName || `Input: rawfile/${CASE_INPUT_DIR}`)
            .fontSize(13)
            .fontColor('#5F6368')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(`Output: ${this.outputDir}`)
            .fontSize(12)
            .fontColor('#5F6368')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          List({ space: 6 }) {
            ForEach(this.results, (item: RenderResult) => {
              ListItem() {
                Row({ space: 8 }) {
                  Text(item.success ? 'OK' : 'ERR')
                    .fontSize(12)
                    .fontColor(item.success ? '#137333' : '#B3261E')
                    .width(36)

                  Text(item.success ? item.name : `${item.name}: ${item.error}`)
                    .fontSize(12)
                    .fontColor(item.success ? '#202124' : '#B3261E')
                    .layoutWeight(1)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
              }
            }, (item: RenderResult) => item.name)
          }
          .height(150)
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .padding(12)
        .backgroundColor('#F8F9FA')
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#FFFFFF')
  }
}
