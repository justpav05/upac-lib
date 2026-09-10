// SPDX-FileCopyrightText: 2026 JustPav
// SPDX-FileCopyrightText: 2026 SmoothTeam
//
// SPDX-License-Identifier: LGPL-3.0-or-later WITH LGPL-3.0-linking-exception

use std::collections::{HashMap, VecDeque};
use std::io::Result as IoResult;

use quick_xml::Writer as XmlWriter;
use quick_xml::events::{BytesDecl, BytesText, Event};

use upac_abi::hook::CancelToken;

use upac_types::hook::ProgressEventBuilder;

use super::{DesktopContent, MimeError, WriteProgress};

use crate::layout::mime::{DESKTOP_FILE_PATH, MIME_XML_PATH, SHARED_MIME_INFO_XMLNS};
use crate::orchestrator::context::{Context, ctx_take};
use crate::orchestrator::stage::{NoRollback, RollbackGuard, Stage, StageResult};
use crate::plugin::decoder::manifest::DecoderManifest;

pub struct RenderingStage;

impl Stage<MimeError> for RenderingStage {
    fn run(
        &self, context: &mut Context, _cancel: &CancelToken, progress: ProgressEventBuilder,
    ) -> Result<(ProgressEventBuilder, StageResult, Box<dyn RollbackGuard>), MimeError> {
        let manifests = ctx_take!(context, HashMap<String, DecoderManifest>);
        let desktop_content = ctx_take!(context, DesktopContent);

        let mime_xml = Self::render_mime_xml(&manifests)?;
        let mime_type_line = Self::render_mime_type_line(&manifests);
        let desktop_content = Self::rewrite_desktop_mime_type(&desktop_content, &mime_type_line)?;

        let pending = VecDeque::from([(MIME_XML_PATH, mime_xml), (DESKTOP_FILE_PATH, desktop_content)]);

        context.put(WriteProgress { pending, total: 2 });

        Ok((progress, StageResult::Advance, Box::new(NoRollback)))
    }
}

impl RenderingStage {
    fn render_mime_xml(manifests: &HashMap<String, DecoderManifest>) -> Result<String, MimeError> {
        let mut writer = XmlWriter::new_with_indent(Vec::new(), b' ', 2);

        writer.write_event(Event::Decl(BytesDecl::new("1.0", Some("UTF-8"), None)))?;

        writer
            .create_element("mime-info")
            .with_attribute(("xmlns", SHARED_MIME_INFO_XMLNS))
            .write_inner_content(|writer| {
                for manifest in manifests.values() {
                    Self::write_mime_type_element(writer, manifest)?;
                }

                Ok(())
            })?;

        let mut body = String::from_utf8_lossy(&writer.into_inner()).into_owned();
        body.push('\n');

        Ok(body)
    }

    fn write_mime_type_element(writer: &mut XmlWriter<Vec<u8>>, manifest: &DecoderManifest) -> IoResult<()> {
        writer
            .create_element("mime-type")
            .with_attribute(("type", manifest.mime.as_str()))
            .write_inner_content(|writer| {
                writer
                    .create_element("comment")
                    .write_text_content(BytesText::new(&manifest.format))?;

                for extension in &manifest.extensions {
                    writer
                        .create_element("glob")
                        .with_attribute(("pattern", format!("*.{extension}").as_str()))
                        .write_empty()?;
                }

                Ok(())
            })?;

        Ok(())
    }

    fn render_mime_type_line(manifests: &HashMap<String, DecoderManifest>) -> String {
        manifests
            .values()
            .map(|manifest| format!("{};", manifest.mime))
            .collect()
    }

    fn rewrite_desktop_mime_type(content: &str, mime_type_line: &str) -> Result<String, MimeError> {
        let mut found = false;
        let mut lines = Vec::with_capacity(content.lines().count());

        for line in content.lines() {
            if line.starts_with("MimeType=") {
                lines.push(format!("MimeType={mime_type_line}"));
                found = true;
            } else {
                lines.push(line.to_owned());
            }
        }

        if !found {
            return Err(MimeError::DesktopFileMalformed);
        }

        Ok(format!("{}\n", lines.join("\n")))
    }
}
