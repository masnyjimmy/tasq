import * as path from "path";
import { workspace, ExtensionContext, commands, window } from "vscode";

import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    State,
    TransportKind,
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;

function createClient(): LanguageClient {
    const config = workspace.getConfiguration("tasq");
    const binaryPath = config.get<string>("path", "tasq");

    const serverOptions: ServerOptions  = {
        run: { command: binaryPath, args: ["--lsp"], transport: TransportKind.stdio},
        debug: {command: binaryPath, args: ["--lsp"], transport: TransportKind.stdio},
    };

    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: "file", language: "tasq"}],
        synchronize: {
            fileEvents: workspace.createFileSystemWatcher("**/tasq"),
        },
    };

    return new LanguageClient("tasq-lsp", serverOptions, clientOptions);
}

async function disposeClient() {
    const old = client;
    client = undefined;
    await old?.dispose();
}

export async function activate(context: ExtensionContext) {
    const stopCommand = commands.registerCommand("tasq.stopLanguageServer", async () => {
        if(!client) {
            window.showInformationMessage('Language client is not initialized.');
            return;
        }

        if(client.state === State.Running) {
            try {
                await client.stop();
                window.showInformationMessage('Language client stop succesfully');
            } catch(error) {
                window.showErrorMessage(`Failed to stop language server: ${error}`);
            }
        } else {
            window.showInformationMessage('Language server is not running');
        }
    });

    const restartCommand = commands.registerCommand("tasq.restartLanguageServer", async () => {
        try {
            await disposeClient();
            client = createClient();
            await client.start();
            window.showInformationMessage("Tasq language server restarted");
        } catch(error) {
            window.showErrorMessage(`Failed to restart language server: ${error}`);
        }
    });

    context.subscriptions.push(stopCommand, restartCommand);

    client = createClient();
    await client.start();
}

export async function deactivate() {
    await client?.dispose();
    client = undefined;
}